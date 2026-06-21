#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:40:00
#SBATCH --job-name=prof-s2z-speed --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §2 zooplankton speed: CPU vs GPU at 128x128x75, 12 steps. CPU exe computes production on CPU,
# GPU exe on GPU -> the (Cobalt: zooplankton calculation) mpp_clock delta is the headline speedup.
# (CPU exe is pre-edit, but our directives are no-ops on the CPU build, so its production time is the valid baseline.)
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
GPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
CPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpu-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
cd "$EXP"
echo "===== SPEED §2: 128x128x75, 12 steps, CPU vs GPU ====="; date; nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null
for tag in cpu gpu; do
  [ "$tag" = gpu ] && E=$GPU || E=$CPU
  rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_12step input.nml
  t0=$(date +%s); "$E" > "out.s2zspeed_$tag" 2>&1; echo "  $tag wall=$(( $(date +%s)-t0 ))s exit=$?"
  grep -E "Total runtime|Cobalt: (zooplankton calculation|phytoplankton growth|carbon|zooplankton|other losses)" "out.s2zspeed_$tag" | sed "s/^/    [$tag] /"
done
echo; echo "===== production-loop speedup ====="
python3 - <<'PY'
import re
def t(tag):
    try: s=open(f"out.s2zspeed_{tag}").read()
    except: return None
    m=re.search(r"Cobalt: zooplankton calculation\S*\s+\d+\s+([\d.]+)", s)
    return float(m.group(1)) if m else None
c,g=t('cpu'),t('gpu')
if c and g: print(f"  zooplankton calculation: CPU={c:.2f}s  GPU={g:.2f}s  speedup={c/g:.2f}x")
else: print(f"  parse failed: cpu={c} gpu={g}  (read out.s2zspeed_* manually)")
PY
echo "==== DONE $(date) ===="
