#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:50:00
#SBATCH --job-name=prof-merge3 --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
GPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
CPU=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpu-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NSYS="$NVHPC/profilers/Nsight_Systems/bin/nsys"; [ -x "$NSYS" ]||NSYS=nsys
cd "$EXP"
echo "===== (A) MERGED step2 (bact+zoo+losses+prod) transfer budget (nsys 1-step = 2 calls; /2 per-call) ====="; date
rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
"$NSYS" profile --force-overwrite=true -o m3_budget "$GPU" >nsysm1.log 2>&1; echo "nsys rc=$?"
echo "##### mem_size_sum #####"; "$NSYS" stats --report cuda_gpu_mem_size_sum m3_budget.nsys-rep 2>/dev/null | grep -iE 'Total|---|Host-to-Device|Device-to-Host|Count' | head -6
echo "##### cuda_api_sum (syncs) #####"; "$NSYS" stats --report cuda_api_sum m3_budget.nsys-rep 2>/dev/null | grep -iE 'StreamSynchronize|Num Calls' | head -4
echo; echo "===== (B) SPEED: CPU vs GPU 12-step (focus losses+production) ====="
for tag in cpu gpu; do
  [ "$tag" = gpu ] && E=$GPU || E=$CPU
  rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_12step input.nml
  t0=$(date +%s); "$E" > "out.m3speed_$tag" 2>&1; echo "  $tag wall=$(( $(date +%s)-t0 ))s exit=$?"
  grep -E "Total runtime|Cobalt: (other losses|production loop|zooplankton|bacteria growth|phytoplankton growth|carbon)" "out.m3speed_$tag" | sed "s/^/    [$tag] /"
done
echo "==== DONE $(date) ===="
