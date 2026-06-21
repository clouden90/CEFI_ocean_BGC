#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:20:00
#SBATCH --job-name=prof-budget --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
EXE=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NSYS="$NVHPC/profilers/Nsight_Systems/bin/nsys"; [ -x "$NSYS" ]||NSYS=nsys
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
echo "=== current 10-kernel build, 1 coupling step = 2 COBALT calls (divide totals by 2 for per-call) ==="; date
"$NSYS" profile --force-overwrite=true -o budget "$EXE" >nsysbud.log 2>&1; echo "nsys rc=$?"
echo; echo "########## (1) KERNEL COMPUTE (cuda_gpu_kern_sum) ##########"
"$NSYS" stats --report cuda_gpu_kern_sum budget.nsys-rep 2>/dev/null | grep -iE 'Total Time|---|update_from_source|Instances' | head -14
echo; echo "########## (2) TRANSFER TIME (cuda_gpu_mem_time_sum) ##########"
"$NSYS" stats --report cuda_gpu_mem_time_sum budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|Host-to-Device|Device-to-Host|memset' | head -8
echo; echo "########## (3) TRANSFER BYTES (cuda_gpu_mem_size_sum) ##########"
"$NSYS" stats --report cuda_gpu_mem_size_sum budget.nsys-rep 2>/dev/null | grep -iE 'Total|---|Host-to-Device|Device-to-Host|Count' | head -8
echo; echo "########## (4) CUDA API: alloc/free/launch/memcpy (cuda_api_sum) ##########"
"$NSYS" stats --report cuda_api_sum budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|Memcpy|MemAlloc|MemFree|HostAlloc|Launch|Synchronize|StreamSync' | head -16
echo "==== DONE $(date) ===="
