#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:40:00
#SBATCH --job-name=prof-s3-perloop --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §3 per-loop timing: CPU vs GPU at 128x128x75, 12 steps. Confirms ballast GPU speedup (Stage 1 result) AND
# gives per-loop source/sink cost (Stage 2 targeting). GPU exe has foodweb+ballast on GPU; source/sink still CPU.
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
GPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
CPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpu-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
cd "$EXP"
echo "===== §3 per-loop: 128x128x75, 12 steps, CPU vs GPU ====="; date
for tag in cpu gpu; do
  [ "$tag" = gpu ] && E=$GPU || E=$CPU
  rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_12step input.nml
  t0=$(date +%s); "$E" > "out.s3speed_$tag" 2>&1; echo "  $tag wall=$(( $(date +%s)-t0 ))s exit=$?"
  grep -E "Total runtime|Cobalt: (ballasting loops|source/sink loop|carbon|phytoplankton growth|zooplankton|other losses|production loop|bacteria)" "out.s3speed_$tag" | sed "s/^/    [$tag] /"
done
echo "==== DONE $(date) ===="
