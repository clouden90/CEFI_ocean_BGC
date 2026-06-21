#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=debug --nodes=1 --ntasks=1 --cpus-per-task=16 --mem=64G --time=00:30:00
#SBATCH --job-name=objrun --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export LD_LIBRARY_PATH="/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11/compilers/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-fortran/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-c/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/hdf5/lib:${LD_LIBRARY_PATH:-}"
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
PD=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpu-nompi/ocean_ice/prod
cd "$EXP"
for tag in cur prist; do
  rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_12step input.nml
  "$PD/MOM6SIS2.O2$tag" > out.objO2_$tag 2>&1; echo "[$tag] exit=$?"
  grep -iE 'phytoplankton growth ca|bacteria growth|zooplankton calc|other losses|production loop|FATAL|Abort' out.objO2_$tag | head -2 | sed 's/^/    /'
done
gc=$(grep -i 'phytoplankton growth ca' "$EXP/out.objO2_cur"|tail -1|awk '{print $5}')
gp=$(grep -i 'phytoplankton growth ca' "$EXP/out.objO2_prist"|tail -1|awk '{print $5}')
echo "COBALT-only -O2 growth: restructured=${gc}s  pristine=${gp}s"
echo "===== Tier-2 -O2 CPU: restructured(§2) vs pristine(pre-§2) per ported section ====="
python3 - <<'PY'
import re
def secs(tag):
    try: s=open(f"/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi/out.objO2_{tag}").read()
    except: return {}
    out={}
    for name in ["phytoplankton growth","bacteria growth","zooplankton calc","other losses","production loop"]:
        m=re.search(rf"{re.escape(name)}\S*\s+\d+\s+([\d.]+)",s)
        if m: out[name]=float(m.group(1))
    return out
c,p=secs("cur"),secs("prist")
print(f"  {'section':24s} {'restr(s)':>9s} {'prist(s)':>9s} {'delta':>8s}")
for k in c:
    if k in p and p[k]>0:
        print(f"  {k:24s} {c[k]:9.2f} {p[k]:9.2f} {(c[k]-p[k])/p[k]*100:+7.1f}%")
PY
