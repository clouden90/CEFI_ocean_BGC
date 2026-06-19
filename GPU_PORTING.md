# COBALT GPU Porting — Strategy, Methodology & References

This document defines **how** we GPU-port COBALT (`generic_COBALT.F90`) for the CEFI ocean-BGC
model, aligned with the MOM6 dynamical-core GPU port. It is the reference every porting PR
follows. The goal is a process where each kernel is **correctness-gated and performance-recorded**,
so the repo carries a tracked ledger of what was changed, why, and what it bought.

## Goals
- **One maintainable, vendor-portable Fortran source** — CPU and GPU from the same code.
- **Align with the MOM6 dycore GPU strategy** so the whole coupled model shares one approach.
- **Every change is correctness-gated (b2b) and performance-recorded (nsys/ncu/cuobjdump).**

## The approach (per kernel)
- **Compute:** standard Fortran `do concurrent` (`-stdpar=gpu`). Where the compiler
  under-parallelizes a complex loop (see below), use an explicit `!$omp target teams loop collapse(N)`.
- **Data residency:** a thin **OpenMP-target** layer — map state once (`!$omp target enter data map(to:)`),
  per-call `target update` only for data crossing the CPU/GPU boundary; compute loops carry **no** map clause.
- **Memory model:** `-gpu=cc90,mem:separate` (no managed/unified auto-migration) — matches the dycore.
- **Reproducibility:** `-Mnofma` (bit-reproducible arithmetic; transcendentals validated by ensemble).

## The per-section optimization loop
For each section we iterate until it hits its roofline / occupancy ceiling:

```
  1. PORT (try)        write the kernel; build the no-MPI exe
  2. b2b GATE ①        restart-diff vs CPU baseline  ── MUST pass before profiling
  3. PROFILE           nsys (time) · ncu (SOL/occupancy/roofline/regs) · cuobjdump (regs/SASS/spills)
                       → identify the binding bottleneck
  4. TUNE              apply the indicated lever (collapse(N), register cap, fusion, tiling, residency)
  5. b2b GATE ②        re-validate correctness AFTER the tuning change
  6. PROFILE again     measure the gain; confirm the bottleneck moved
  7. REPEAT 4–6        until optimized (roofline-bound or diminishing returns)
  8. PR                record before/after (b2b PASS, nsys/ncu/cuobjdump, verdict) → merge → ledger
```

**Hard rule:** no performance change merges without a **passing b2b in the same PR**.

**b2b definition:** restart-file diff vs the CPU baseline. Pure-arithmetic blocks must be
**bit-identical**; `exp`/transcendental blocks are validated against a **CPU round-off ensemble**
(GPU result must fall inside the natural round-off band) — transcendentals are IEEE-permitted to
differ at the last ULP. b2b is checked at the **section-output level** (kernels share resident state).

## Profiling infrastructure
- `ncu` **cannot** profile through the coupled model's HPC-X `mpirun`. We build the whole
  MOM6SIS2+COBALT model **without MPI** (serial FMS `_nocomm` backend + `nvfortran`/`nvc`,
  dropping `-Duse_libMPI`), giving a launcher-free `./MOM6SIS2` that `ncu` attaches to directly.
  This profiles the **real** in-model kernels — a standalone reproduction proved *misleading*
  (it hid a 5× under-parallelization bug).
- **Single source of truth:** the build compiles `cefi/src/ocean_BGC`; it must be kept in sync
  with this repo when iterating.

## Status tracker (living — update each PR)
| section | line | construct | b2b | profiled (real model) | optimized |
|---|---|---|---|---|---|
| §1.1 nutrient lim | 3513 | `do concurrent(k,j,i)` | aggregate | yes — under-parallelized, 6.25% occ | ❌ `collapse(3)` pending |
| B light attenuation | 3656 | `do concurrent(j,i) local()` | aggregate | yes — 255 regs, local-mem spill | ❌ |
| C acclimation | 3756 | `do concurrent(k,j,i)` | aggregate | yes — under-parallelized | ❌ `collapse(3)` pending |
| E Geider growth | 3794 | `omp target teams loop collapse(3)` | ⚠️ re-validate after change | yes — 272→54 ms (5×), now reg-bound | ◑ 1 pass |
| F mixed-layer avg | 3872 | `do concurrent(j,i,n) local()` | aggregate | yes — **#1 kernel, ~97% idle** | ❌ |
| G growth-memory | 3887 | `do concurrent(k,j,i,n)` | aggregate | partial | ❌ |

*(Ported so far = the growth pathway §1.1+§1.2 ≈ 10% of the 4,000-line reaction network. Remaining
big targets: carbon chemistry / CO₂-pH solver (#1 CPU cost), zooplankton, production, remineralization.)*

---

## References

### A. MOM6 dynamical-core GPU lessons (Ward & Yang, GFDL)
Mnemonic — **CONCURRENT → RESIDENT → FUSE → INLINE → REPRODUCE**:
1. **Concurrent** — `do concurrent` compute; OpenMP only for data; managed memory was ~5× slower → `mem:separate`.
2. **Resident** — map state once; per-call host↔device transfers are the real cost.
3. **Fuse** — big fused 3D kernels; never put a directive on a deep inner loop (≈3×10⁶ launches → 265 s disaster).
4. **Inline** — no subroutine calls inside kernels; inline (`-Minline`/`!NVF$ INLINE`) or pass private scratch.
5. **Reproduce** — arithmetic bit-exact with `-Mnofma`; transcendentals differ at last-ULP; split loops with cross-loop dependencies.

MOM6 measured result: **24% cheaper / 12% faster / 30% more energy-efficient**, bit-reproducible, no code
duplication — but the port is the **dynamical core only, not COBALT/BGC** (the poster even notes "GPU
underutilized when running tests"). BGC is the open, complementary work — and it is *required* to keep the
coupled model's tracers resident once the dycore is on GPU (otherwise a per-step transfer wall erases the gains).

### B. Deep-research findings (2024–2026, adversarially verified)
- The **`do concurrent` + thin OpenMP-data + `mem:separate`** hybrid is the documented state of the art
  (HipFT, MOM6, solar-MHD). On unified-memory APUs (GH200/MI300A) the data directives can be dropped.
- **`collapse(N)` is the published fix** for `do concurrent` under-parallelization: WRF/Codee (SC24) measured
  `collapse(2)→collapse(3)` lifting occupancy **4.63%→35.67%** — the same mechanism as our COBALT block-E
  result (**6.25%→18.74%, 5×**). HipFT documents the matching nvfortran/ifx limitation.
- **Register pressure** is a tunable occupancy limiter — cap toward **~64 regs/thread** (`launch_bounds`/split);
  no further benefit below ~64.
- **Cross-vendor (2025–26):** nvfortran most mature; Intel ifx DC-offload is flag-gated and offloads *compute*
  only (still needs manual data maps); HPE Cray CCE is the only AMD DC path; GCC has no DC-GPU; LLVM Flang is
  experimental. → **keep the OpenMP-target *data* layer as the portability anchor**; macro-wrap compute
  (`loop` ↔ `teams distribute parallel do`) for AMD/Intel.
- OpenMP 6.0 released 2024-11-14 (the `loop` construct). Literature can't yet adjudicate `loop` vs
  `teams distribute parallel do`.

**Sources:** HipFT arXiv:2408.07843 (IEEE 10820592) · WRF/Codee arXiv:2409.07232 (SC24 WACCPD) ·
solar-MHD arXiv:2303.03398 · MOM6 SC-Asia 2026 poster P-103 + github.com/marshallward ·
NVIDIA HPC SDK `do concurrent` blog · Intel ifx 2025 release notes · openmp.org/articles/openmp-6 ·
ICON GMD 19,755-2026 · Oceananigans JAMES 2024MS004465.
