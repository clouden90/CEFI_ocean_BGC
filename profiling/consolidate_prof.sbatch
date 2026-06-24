#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=8 --gres=gpu:h100:1 --mem=64G --time=00:40:00
#SBATCH --job-name=consol-prof --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §3 consolidation profiling on the M2 GPU exe: (A) nsys transfer budget -> HtoD/DtoH VOLUME (the M2 win:
#   re-HtoD eliminated; baseline foodweb-only merge4 was HtoD 2.3GB / DtoH 7.0GB). (B) ncu occupancy on the
#   source/sink + ballast kernels (esp. loop6's big fused kernel F1L~6xxx — occupancy/register tuning candidate).
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
EXE=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NSYS="$NVHPC/profilers/Nsight_Systems/bin/nsys"; [ -x "$NSYS" ]||NSYS=nsys
NCU="$NVHPC/profilers/Nsight_Compute/ncu"; [ -x "$NCU" ]||NCU="$NVHPC/compilers/bin/ncu"
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
date; echo "EXE: $EXE"
echo "===== (A) nsys transfer budget (1 step = 2 COBALT calls) ====="
"$NSYS" profile --force-overwrite=true -o consol_budget "$EXE" >nsys_consol.log 2>&1; echo "nsys rc=$?"
echo "##### mem_size_sum (HtoD/DtoH TOTAL volume — M2 win vs merge4 HtoD 2.3GB/DtoH 7.0GB) #####"
"$NSYS" stats --report cuda_gpu_mem_size_sum consol_budget.nsys-rep 2>/dev/null | grep -iE 'Total|---|Host-to-Device|Device-to-Host|Count' | head -8
echo "##### mem_time_sum (transfer TIME) #####"
"$NSYS" stats --report cuda_gpu_mem_time_sum consol_budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|Host-to-Device|Device-to-Host' | head -6
echo "##### distinct kernels launched (expect 23: 28 compiled, do_resp_ca_diss + do_14c gated off) #####"
"$NSYS" stats --report cuda_gpu_kern_sum consol_budget.nsys-rep 2>/dev/null | grep -c 'update_from_source'
echo; echo "===== (B) ncu occupancy: source/sink + ballast kernels (--set basic on update_from_source) ====="
"$NCU" --set basic -k 'regex:update_from_source' -c 24 -f -o consol_ncu "$EXE" >ncu_consol.log 2>&1; echo "ncu rc=$?"
"$NCU" --import consol_ncu.ncu-rep --page details 2>/dev/null | grep -iE 'update_from_source|Registers Per Thread|Achieved Occupancy|Theoretical Occupancy|Compute \(SM\) Throughput|DRAM Throughput' | sed 's/^/  /'
echo "==== DONE $(date) ===="
