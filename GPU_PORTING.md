# COBALT GPU Porting — Strategy, Methodology & References

This document defines **how** we GPU-port COBALT (`generic_COBALT.F90`) for the CEFI ocean-BGC
model, aligned with the MOM6 dynamical-core GPU port. **Every GPU PR follows it.** The goal is a
process where each section is **correctness-gated and performance-recorded**, so the repo carries a
tracked ledger of what changed, why, and what it bought — section by section, from a clean baseline.

## Goals
- **One maintainable, vendor-portable Fortran source** — CPU and GPU from the same code.
- **Align with the MOM6 dycore GPU strategy** so the whole coupled model shares one approach.
- **Every change is correctness-gated (b2b) and performance-recorded (nsys + ncu, plus cuobjdump).**
- Build the port up **one validated section at a time** from the clean `feature/gpu` baseline —
  never bulk-import unvalidated work.

## The approach (per kernel)
- **Compute:** standard Fortran `do concurrent` (`-stdpar=gpu`). Where the compiler under-parallelizes
  a complex loop (serializes a dimension), use an explicit `!$omp target teams loop collapse(N)`.
- **Data residency:** a thin **OpenMP-target** layer — map state once (`!$omp target enter data map(to:)`),
  per-call `target update` only for data crossing the CPU/GPU boundary; compute loops carry **no** map clause.
- **Memory model:** `-gpu=cc90,mem:separate` (no managed/unified auto-migration) — matches the dycore.
- **Reproducibility:** `-Mnofma` (bit-reproducible arithmetic; transcendentals validated by ensemble).

## The baseline (what every b2b compares against)
- **CPU baseline** = the *same* `generic_COBALT.F90` source, compiled **CPU-only** with the production
  reproducibility flags (`-O0 -Mnovect -Mnofma -i4 -r8 -byteswapio`), run on the **pinned test case**.
- **GPU build** = the *same* source + GPU flags (`-stdpar=gpu -mp=gpu -gpu=cc90,mem:separate`) scoped to
  `generic_COBALT.o`, run on the **same** test case, **same** step count.
- **Pinned test case (current):** `OM4.scale128.COBALT` (128×128×75 = 1.23 M cells), `input.nml_min`
  (DT override → 6 COBALT calls), empty `diag_table`, single PE.
- Each section PR **pins the baseline commit + test case + step count** so the comparison is reproducible.

## The per-section optimization loop
Run for **every** section, iterating until it hits its roofline / occupancy ceiling:

```
 1. PORT          lift/write the section kernel; build the no-MPI exe (CPU baseline + GPU build)

 2. b2b GATE ①    run CPU baseline and GPU on the SAME pinned test case; diff the section outputs
                    ├─ bit-identical .............. PASS  → record the matching value(s)
                    └─ NOT bit-identical .......... MANDATORY cuobjdump:
                         • dump SASS, locate the divergent instruction(s) — MUFU.EX2 (=exp),
                           MUFU.RCP/div helpers, any FMA — i.e. WHY it differs;
                         • run the CPU round-off ensemble; GPU value MUST fall inside the band;
                         • write the explanation in the PR.
                         A diff NOT explained by transcendental round-off = a BUG → fix before proceeding.

 3. PROFILE        RECORD all three (these are PR artifacts, not optional):
                    • nsys  — kernel-time table
                    • ncu   — SOL (compute/mem %), occupancy (achieved/theoretical), regs/thread, roofline
                    • cuobjdump — regs, local-memory spills, key SASS
                    → identify the binding bottleneck

 4. TUNE           apply the indicated lever: collapse(N) (parallelism), register cap → ~64
                   (launch_bounds/split), kernel fusion, tiling/JIK ordering, residency fix

 5. b2b GATE ②     re-run b2b after the tuning change (a perf change can break correctness)

 6. PROFILE again  RECORD nsys + ncu again; confirm the bottleneck moved / occupancy rose

 7. REPEAT 4–6     until optimized (roofline/occupancy-bound or diminishing returns)

 8. PR             open into feature/gpu with the FULL record (see checklist) → review → merge → ledger
```

**Hard rules**
- No performance change merges without a **passing b2b in the same PR** (PASS = bit-identical, *or*
  a divergence proven to be transcendental round-off via cuobjdump + ensemble).
- A section is "done" only when **optimized** (roofline/occupancy-bound), with the final profile recorded.
- b2b is checked at the **section-output level** (kernels share resident state — you can't bit-check one in isolation).

## What every section PR MUST contain (checklist)
- [ ] **Baseline pinned** — CPU-baseline commit, test case, step count.
- [ ] **Code** — the section's GPU change (construct + directives), one section per PR.
- [ ] **b2b result** — one of:
  - PASS, bit-identical (quote the matching value), **or**
  - documented round-off: cuobjdump SASS excerpt of the divergent instruction(s) (e.g. `MUFU.EX2`),
    the CPU round-off ensemble band, the GPU value shown inside it, and a one-line "why it's acceptable."
- [ ] **nsys** — kernel-time table, **before → after**.
- [ ] **ncu** — SOL (compute/mem %), achieved/theoretical occupancy, registers/thread, roofline point, **before → after**.
- [ ] **cuobjdump** — registers, local-memory spills, key SASS (the optimization evidence).
- [ ] **Tuning analysis** — bottleneck found → lever applied → measured effect → remaining limiter.
- [ ] **Status tracker updated** (the table below).

## Profiling infrastructure
- `ncu` **cannot** profile through the coupled model's HPC-X `mpirun`. We build the whole
  MOM6SIS2+COBALT model **without MPI** (serial FMS `_nocomm` backend + `nvfortran`/`nvc`, dropping
  `-Duse_libMPI`), giving a launcher-free `./MOM6SIS2` that `ncu` attaches to directly. This profiles
  the **real** in-model kernels — a standalone reproduction proved *misleading* (it hid a 5×
  under-parallelization bug).
- **Single source of truth:** the build compiles `cefi/src/ocean_BGC`; keep it synced with this repo when iterating.

## Status tracker (living — update each PR)
| section | line | construct | b2b | profiled (real model) | optimized |
|---|---|---|---|---|---|
| §1.1 nutrient lim | 3513 | `do concurrent(k,j,i)` | aggregate only | yes — under-parallelized, 6.25% occ | ❌ `collapse(3)` pending |
| B light attenuation | 3656 | `do concurrent(j,i) local()` | aggregate only | yes — 255 regs, local-mem spill | ❌ |
| C acclimation | 3756 | `do concurrent(k,j,i)` | aggregate only | yes — under-parallelized | ❌ `collapse(3)` pending |
| E Geider growth | 3794 | `omp target teams loop collapse(3)` | ⚠️ re-validate after change | yes — 272→54 ms (5×), now reg-bound | ◑ 1 pass |
| F mixed-layer avg | 3872 | `do concurrent(j,i,n) local()` | aggregate only | yes — **#1 kernel, ~97% idle** | ❌ |
| G growth-memory | 3887 | `do concurrent(k,j,i,n)` | aggregate only | partial | ❌ |

*Ported so far = the growth pathway §1.1+§1.2 ≈ 10% of the 4,000-line reaction network. All rows above
predate this methodology and must be re-run through the loop from the clean baseline. Remaining big
targets: carbon chemistry / CO₂-pH solver (#1 CPU cost), zooplankton, production, remineralization.*

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
