[![cobalt CI](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml/badge.svg?branch=dev%2Fcefi)](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml)

## GPU porting

COBALT is being GPU-ported on this `feature/gpu` integration branch — a portable, ISO-standard
approach (`do concurrent` + thin OpenMP-target residency on `mem:separate`) aligned with the MOM6
dynamical-core GPU port. We build the GPU port up **one section at a time, from this clean
baseline**, and each section passes a rigorous, recorded loop before it lands.

**Methodology, references & status → [GPU_PORTING.md](GPU_PORTING.md):**
- the per-section optimization loop: **port → b2b → profile → tune → b2b → profile, until optimized**
  (b2b is a hard correctness gate — no perf change merges without a passing b2b);
- the profiling infrastructure (no-MPI build so `ncu` profiles the *real* in-model kernels);
- a living per-section status tracker;
- references: the **MOM6 dynamical-core GPU lessons** (Ward & Yang, GFDL) and the
  **adversarially-verified deep-research findings** (the `collapse(N)` under-parallelization fix,
  register target, cross-vendor support matrix), with citations.

Every GPU PR targets `feature/gpu` and records its b2b + nsys/ncu/cuobjdump results.
