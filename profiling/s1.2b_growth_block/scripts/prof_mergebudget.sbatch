#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:20:00
#SBATCH --job-name=prof-mbud --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
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
"$NSYS" profile --force-overwrite=true -o mbud "$EXE" >nsysmbud.log 2>&1; echo "nsys rc=$?"
echo "## KERNEL COMPUTE ##"; "$NSYS" stats --report cuda_gpu_kern_sum mbud.nsys-rep 2>/dev/null | grep -iE 'Total Time|---|update_from_source' | head -12
echo "## TRANSFER TIME (was: DtoH 282 ops/427ms, HtoD 1392 ops/318ms over 2 calls) ##"; "$NSYS" stats --report cuda_gpu_mem_time_sum mbud.nsys-rep 2>/dev/null | grep -iE 'Time|---|Host-to-Device|Device-to-Host' | head -6
echo "## TRANSFER BYTES (was 6768 MB over 2 calls) ##"; "$NSYS" stats --report cuda_gpu_mem_size_sum mbud.nsys-rep 2>/dev/null | grep -iE 'Total|---|Host-to-Device|Device-to-Host' | head -6
echo "## API: sync/alloc/launch (was 190 sync over 2 calls) ##"; "$NSYS" stats --report cuda_api_sum mbud.nsys-rep 2>/dev/null | grep -iE 'Time|---|Memcpy|MemAlloc|MemFree|Synchronize|Launch' | head -12
echo "DONE"
