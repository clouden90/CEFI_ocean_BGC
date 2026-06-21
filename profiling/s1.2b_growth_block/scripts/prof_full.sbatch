#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-h100 --qos=gpuwf --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:h100:1 --mem=128G --time=00:40:00
#SBATCH --job-name=prof-full --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.scale128.COBALT.nompi
EXE=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-sep-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
NCU="$NVHPC/profilers/Nsight_Compute/ncu"; [ -x "$NCU" ]||NCU="$NVHPC/compilers/bin/ncu"
cd "$EXP"; rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_1step input.nml
echo "===== (A) --set full: all 10 cobalt kernels (one COBALT call) ====="
"$NCU" --set full -k 'regex:update_from_source' -c 10 -f -o full10 "$EXE" >ncufull.log 2>&1; echo "set-full rc=$?"
"$NCU" --import full10.ncu-rep --page details 2>/dev/null | grep -iE 'void |update_from_source|Grid Size|Block Size|Registers Per Thread|Theoretical Occupancy|Achieved Occupancy|Compute \(SM\) Throughput|Memory Throughput|DRAM Throughput|Duration|Executed Ipc Active|Warp Cycles Per Issued|L2 Hit Rate' | sed 's/^/  /'
echo
echo "===== (B) ROOFLINE metrics: DP-FLOPs + DRAM bytes -> arithmetic intensity + GFLOP/s ====="
"$NCU" -k 'regex:update_from_source' -c 10 -f -o roof10 \
  --metrics sm__sass_thread_inst_executed_op_dadd_pred_on.sum,sm__sass_thread_inst_executed_op_dmul_pred_on.sum,sm__sass_thread_inst_executed_op_dfma_pred_on.sum,dram__bytes.sum,gpu__time_duration.sum \
  "$EXE" >ncuroof.log 2>&1; echo "roofline rc=$?"
"$NCU" --import roof10.ncu-rep --page raw 2>/dev/null | grep -iE 'update_from_source|dadd|dmul|dfma|dram__bytes|time_duration' | sed 's/^/  /' | head -70
echo "==== DONE $(date) ===="
