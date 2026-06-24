#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=batch --nodes=1 --ntasks=1 --cpus-per-task=16 --mem=96G --time=03:00:00
#SBATCH --job-name=tier2b-O2nv --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# Tier-2b: build the coupled model at -O2 -Mnovect (new platform x86-cpuO2nv-nompi) and run b2b.
# HYPOTHESIS: the Tier-2 (-O2, vectorized) init crash "%CON extra close block" is an nvfortran 24.11
# -O2 VECTORIZER miscompile of FMS field_manager string parsing -> -Mnovect should make FMS parse
# again. If it parses + COBALT runs + matches the reference within round-off, Tier-2 is root-caused
# AND we gain genuine -O2-scalar correctness coverage of the COBALT port.
B=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.single_column.COBALT.b2b
EXE=$B/build/nvhpc-x86-cpuO2nv-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
export MAKEFLAGS="-j8"   # from-scratch new platform; moderate -j to limit libyaml race, verify below
date
echo "===== build x86-cpuO2nv-nompi (-O2 -Mnovect) ====="
cd "$B"
bash linux-build-nompi.bash -m nvhpc -p x86-cpuO2nv-nompi -t prod -f mom6sis2 \
   > /scratch5/purged/Yi-cheng.Teng/tmp/logs/build_x86cpuO2nv_nompi.out 2>&1
rc=$?; echo "  build rc=$rc"
echo "  libyaml.a: $(ls -l $B/build/libyaml/prod/lib/libyaml.a 2>/dev/null | awk '{print $5}' || echo MISSING)"
if [ ! -x "$EXE" ]; then
  echo "  *** EXE MISSING — build failed (likely libyaml race; retry incremental). tail: ***"
  tail -25 /scratch5/purged/Yi-cheng.Teng/tmp/logs/build_x86cpuO2nv_nompi.out
  echo "==== ABORT $(date) ===="; exit 1
fi
echo "  EXE OK $(du -h "$EXE"|cut -f1); MPI syms(want 0)=$(nm "$EXE" 2>/dev/null|grep -ciE 'mpi_init|PMPI_'); CUDA syms(want 0)=$(nm "$EXE" 2>/dev/null|grep -ciE 'cuda|nvkernel')"
echo "===== run b2b (clean dir) ====="
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; rm -f _read_error.nml logfile*.out; ln -sfn input.nml_48hr input.nml
"$EXE" > out.tier2b 2>&1; echo "  run exit=$?"
grep -iE 'FATAL|extra close block|NaN|imbalance' out.tier2b | head -3 | sed 's/^/  STAB: /'
python3 - <<'PY'
import subprocess
ref={'dic':1.5036917557803020e13,'alk':1.6266596567821816e13,'no3':1.1316293002204030e11,
     'po4':7.5339387331740561e9,'o2':1.6808058953017490e12}
def val(name):
    o=subprocess.run(f"grep 'Total {name}:' out.tier2b|tail -1|awk '{{print $3}}'",shell=True,capture_output=True,text=True).stdout.strip()
    try: return float(o.replace('E','e'))
    except: return float('nan')
print("== TIER-2b (-O2 -Mnovect) vs reference (within round-off ~1e-12) ==")
allok=True
for k,r in ref.items():
    v=val(k); rel=abs(v-r)/abs(r) if r else abs(v-r); ok=rel<=1e-12
    allok=allok and ok; print(f"  {k:5s} {v:24.16e}  rel={rel:.2e}  {'OK' if ok else 'XX'}")
print(f"  ===== TIER-2b VERDICT: {'PASS' if allok else 'FAIL/CRASH'} =====")
PY
echo "==== DONE $(date) ===="
