#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=8 --gres=gpu:h100:1 --mem=64G --time=00:20:00
#SBATCH --job-name=prof-s3bal-sanity --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §3 ballast SANITY: confirm the 7 new ballast kernels actually LAUNCH on GPU (cuobjdump shows them in the
# binary; this proves they execute) + their per-call cost. 128x128x75, 1 step. Expect 24 distinct
# update_from_source kernels in cuda_gpu_kern_sum (17 foodweb + 7 ballast).
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
EXE=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NSYS="$NVHPC/profilers/Nsight_Systems/bin/nsys"; [ -x "$NSYS" ]||NSYS=nsys
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
date; echo "EXE: $EXE"
"$NSYS" profile --force-overwrite=true -o s3bal_sanity "$EXE" >nsys_s3bal.log 2>&1; echo "nsys rc=$?"
echo "##### distinct update_from_source kernels launched (expect 24) #####"
"$NSYS" stats --report cuda_gpu_kern_sum s3bal_sanity.nsys-rep 2>/dev/null | grep -c 'update_from_source' | sed 's/^/  distinct kernels: /'
echo "##### kern_sum (all update_from_source rows: time + instances) #####"
"$NSYS" stats --report cuda_gpu_kern_sum s3bal_sanity.nsys-rep 2>/dev/null | grep -iE 'Time|---|update_from_source' | head -30
echo "==== DONE $(date) ===="
