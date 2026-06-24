#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=batch --nodes=1 --ntasks=1 --cpus-per-task=8 --mem=64G --time=00:40:00
#SBATCH --job-name=tier2c-parserO0 --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# Tier-2c: surgical fix on the cpuO2nv build. The -O2 init crash is in MOM6's OWN param-file parser
# (get_variable_line in MOM_file_parser.F90), NOT vectorization (Tier-2b -O2 -Mnovect still crashed)
# and NOT the COBALT port. Recompile ONLY MOM_file_parser.o at -O0 (textbook single-file-miscompile
# workaround), keep everything else -- crucially generic_COBALT.o -- at -O2, relink, run b2b.
# If it matches the reference, Tier-2 is closed AND we have genuine -O2 coverage of the COBALT port.
BL=/scratch5/purged/Yi-cheng.Teng/tmp/logs/build_x86cpuO2nv_nompi.out
BD=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpuO2nv-nompi/ocean_ice/prod
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.single_column.COBALT.b2b
EXE=$BD/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
date
cd "$BD" || { echo "build dir missing"; exit 1; }

echo "===== extract exact compile + link commands from build log ====="
CC=$(grep -E 'MOM_file_parser\.F90' "$BL" | grep -E -- ' -c ' | tail -1)
LK=$(grep -E ' -o MOM6SIS2 ' "$BL" | tail -1)
[ -n "$CC" ] && [ -n "$LK" ] || { echo "FAILED to extract commands (CC empty=$([ -z "$CC" ]&&echo Y) LK empty=$([ -z "$LK" ]&&echo Y))"; exit 1; }
CC0=${CC/ -O2 / -O0 }   # downgrade ONLY this file to -O0
echo "  compile (-O0) flags: ...$(echo "$CC0" | grep -oE '\-g -O0 -Mnovect -Mnofma')..."
[ "$CC0" = "$CC" ] && { echo "  *** -O2->-O0 substitution did not change the line — abort ***"; exit 1; }

echo "===== recompile MOM_file_parser.o at -O0 ====="
eval "$CC0"; echo "  compile rc=$?  -> $(ls -l MOM_file_parser.o 2>/dev/null | awk '{print $5,$6,$7,$8}')"
echo "===== relink MOM6SIS2 (all other .o stay -O2, incl. generic_COBALT.o) ====="
eval "$LK"; echo "  link rc=$?"
[ -x "$EXE" ] || { echo "  *** EXE missing after relink ***"; exit 1; }
echo "  EXE $(du -h "$EXE"|cut -f1)  $(date -r "$EXE" '+%H:%M:%S')"

echo "===== run b2b (clean dir) ====="
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; rm -f _read_error.nml logfile*.out; ln -sfn input.nml_48hr input.nml
"$EXE" > out.tier2c 2>&1; echo "  run exit=$?"
grep -iE 'FATAL|extra close block|NaN|imbalance' out.tier2c | head -3 | sed 's/^/  STAB: /'
python3 - <<'PY'
import subprocess
ref={'dic':1.5036917557803020e13,'alk':1.6266596567821816e13,'no3':1.1316293002204030e11,
     'po4':7.5339387331740561e9,'o2':1.6808058953017490e12}
def val(name):
    o=subprocess.run(f"grep 'Total {name}:' out.tier2c|tail -1|awk '{{print $3}}'",shell=True,capture_output=True,text=True).stdout.strip()
    try: return float(o.replace('E','e'))
    except: return float('nan')
print("== TIER-2c (-O2 everywhere, MOM_file_parser.o @ -O0) vs reference (within round-off ~1e-12) ==")
allok=True
for k,r in ref.items():
    v=val(k); rel=abs(v-r)/abs(r) if r else abs(v-r); ok=rel<=1e-12
    allok=allok and ok; print(f"  {k:5s} {v:24.16e}  rel={rel:.2e}  {'OK' if ok else 'XX'}")
print(f"  ===== TIER-2c VERDICT: {'PASS (-O2 COBALT coverage achieved)' if allok else 'FAIL/CRASH'} =====")
PY
echo "==== DONE $(date) ===="
