#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=debug --nodes=1 --ntasks=1 --cpus-per-task=16 --mem=32G --time=00:30:00
#SBATCH --job-name=objswap --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11/compilers/bin:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-fortran/bin:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-c/bin:$PATH"
export LD_LIBRARY_PATH="/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11/compilers/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-fortran/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/netcdf-c/lib:/scratch5/purged/Yi-cheng.Teng/tmp/stack/install/hdf5/lib:${LD_LIBRARY_PATH:-}"
PD=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpu-nompi/ocean_ice/prod
BC=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/src/ocean_BGC/generic_tracers/generic_COBALT.F90
REPO=/scratch5/purged/Yi-cheng.Teng/tmp/cefi_ocean_BGC
COMPILE=$(cat /tmp/cobalt_o2_compile.cmd)
cd "$PD"
echo "save -O0 state"; cp generic_COBALT.o generic_COBALT.o.O0bak; cp MOM6SIS2 MOM6SIS2.O0bak
build_variant(){ # $1=ref $2=tag
  git -C "$REPO" show $1:generic_tracers/generic_COBALT.F90 > "$BC"
  rm -f generic_COBALT.o; eval "$COMPILE" && echo "  [$2] -O2 compile OK ($(ls -la generic_COBALT.o|awk '{print $5}') bytes)" || { echo "  [$2] COMPILE FAILED"; return 1; }
  make MOM6SIS2 >/dev/null 2>&1 && cp MOM6SIS2 MOM6SIS2.O2$2 && echo "  [$2] relink OK -> MOM6SIS2.O2$2" || echo "  [$2] RELINK FAILED"
}
build_variant HEAD cur
build_variant feature/gpu prist
echo "restore -O0 reference"
git -C "$REPO" show HEAD:generic_tracers/generic_COBALT.F90 > "$BC"
cp generic_COBALT.o.O0bak generic_COBALT.o; touch generic_COBALT.o; cp MOM6SIS2.O0bak MOM6SIS2
echo "  -O0 exe restored: MPI/CUDA symbols=$(nm MOM6SIS2 2>/dev/null|grep -ciE 'mpi_init|cuda|nvkernel') (want 0)"
echo "OBJSWAP_BUILD_DONE"
