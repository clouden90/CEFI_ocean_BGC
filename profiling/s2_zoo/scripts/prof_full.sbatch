#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:50:00
#SBATCH --job-name=prof-s2z-full --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §2 zooplankton port profiling: 12 cobalt kernels now (growth's 10 + zoo F1L4278 + production F1L4748).
# -c 12 captures all of them in launch order. CSV dumps feed make_figs.py.
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
EXE=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NCU="$NVHPC/profilers/Nsight_Compute/ncu"; [ -x "$NCU" ]||NCU="$NVHPC/compilers/bin/ncu"
NSYS="$NVHPC/profilers/Nsight_Systems/bin/nsys"; [ -x "$NSYS" ]||NSYS=nsys
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
date; echo "EXE: $EXE"

echo "===== (A) --set full: all 11 cobalt kernels (one COBALT call) ====="
"$NCU" --set full -k 'regex:update_from_source' -c 12 -f -o s2z_full12 "$EXE" >ncufull.log 2>&1; echo "set-full rc=$?"
"$NCU" --import s2z_full12.ncu-rep --page details 2>/dev/null | grep -iE 'update_from_source|Grid Size|Block Size|Registers Per Thread|Theoretical Occupancy|Achieved Occupancy|Compute \(SM\) Throughput|Memory Throughput|DRAM Throughput|Duration|Executed Ipc Active|Warp Cycles Per Issued|L2 Hit Rate' | sed 's/^/  /'
"$NCU" --import s2z_full12.ncu-rep --csv --page details 2>/dev/null > s2z_full12.csv; echo "  CSV: $(wc -l <s2z_full12.csv) lines -> s2z_full12.csv"

echo; echo "===== (B) ROOFLINE metrics: DP-FLOPs + DRAM bytes ====="
"$NCU" -k 'regex:update_from_source' -c 12 -f -o s2z_roof12 \
  --metrics sm__sass_thread_inst_executed_op_dadd_pred_on.sum,sm__sass_thread_inst_executed_op_dmul_pred_on.sum,sm__sass_thread_inst_executed_op_dfma_pred_on.sum,dram__bytes.sum,gpu__time_duration.sum \
  "$EXE" >ncuroof.log 2>&1; echo "roofline rc=$?"
"$NCU" --import s2z_roof12.ncu-rep --page raw 2>/dev/null | grep -iE 'update_from_source|dadd|dmul|dfma|dram__bytes|time_duration' | sed 's/^/  /'
"$NCU" --import s2z_roof12.ncu-rep --csv --page raw 2>/dev/null > s2z_roof12.csv; echo "  CSV: $(wc -l <s2z_roof12.csv) lines -> s2z_roof12.csv"

echo; echo "===== (C) nsys: kernel time + transfer budget (1 step = 2 COBALT calls; /2 per-call) ====="
"$NSYS" profile --force-overwrite=true -o s2z_budget "$EXE" >nsysbud.log 2>&1; echo "nsys rc=$?"
echo "##### kern_sum #####"; "$NSYS" stats --report cuda_gpu_kern_sum s2z_budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|update_from_source|Instances' | head -16
echo "##### mem_time_sum #####"; "$NSYS" stats --report cuda_gpu_mem_time_sum s2z_budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|Host-to-Device|Device-to-Host|memset' | head -8
echo "##### mem_size_sum #####"; "$NSYS" stats --report cuda_gpu_mem_size_sum s2z_budget.nsys-rep 2>/dev/null | grep -iE 'Total|---|Host-to-Device|Device-to-Host|Count' | head -8
echo "##### cuda_api_sum #####"; "$NSYS" stats --report cuda_api_sum s2z_budget.nsys-rep 2>/dev/null | grep -iE 'Time|---|Memcpy|MemAlloc|MemFree|Launch|Synchronize|StreamSync' | head -16
echo "==== DONE $(date) ===="
