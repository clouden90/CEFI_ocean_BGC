<!-- GPU-PORT-SECTION -->
# COBALT GPU Port — OpenACC (managed memory)

This branch is the **first** GPU port of the COBALT biogeochemistry reaction loops (`generic_COBALT.F90`), using NVIDIA OpenACC directives. (A portable `do concurrent` + OpenMP rebuild lives on the sister branch.)

## Approach
- **Compute:** OpenACC **`!$acc parallel loop gang vector collapse(3)`** on the triple-nested reaction loops — one GPU thread per ocean cell. Wrapped via a `COBALT_GPU_LOOP3` macro so the same source can target OpenACC (`-DCOBALT_GPU_ACC`), OpenMP-target, or plain `do concurrent`.
- **Data:** **managed / unified memory** (`-gpu=cc90,mem:managed`) — the runtime migrates pages on demand, so **no explicit data directives**. Residency *within* a contiguous block of GPU loops is automatic (migrate once at the block boundary, not per loop).
- **Trade-off:** simple and fast to stand up, but **NVIDIA-only**, and managed memory is a different memory model than the MOM6 dynamics core — which is why the work was later rebuilt portably (sister branch).

## Scope
~30 reaction loops offloaded: nutrient uptake → bacteria → zooplankton → production → remineralization → iron (Block A), the source/sink tendency loops (Block B), and the photoacclimation/Geider growth loop.

## Benchmark
- **GH200 (in-container, OM4 1.2 M cells):** offloaded BGC block **62.8 s → 10.3 s = 6.1×**; total coupled model 1.22× (Amdahl — COBALT is ~23% of coupled runtime; dynamics + carbon-chem still on CPU).
- **H100 NVL (scale128, 6 calls):** `Cobalt: phytoplankton growth` clock **12.74 s** vs **39.18 s** CPU (≈3.1×) — on par with the do-concurrent rebuild (12.35 s).

## Correctness
Rigorous restart-file diff vs the CPU baseline: pure-arithmetic source/sink loops are **bit-for-bit identical (0.0)**; the only divergence is **device-`exp()` last-ULP** in the growth/remineralization loops (worst relative diff 7.78e-14), propagated exactly where the physics predicts — no race / `firstprivate` bug.

## Build flags
```
# generic_COBALT.o only:  -acc=gpu -gpu=cc90,mem:managed -Minfo=accel -DCOBALT_GPU_ACC
```
Scoped to the one file via a target-specific make rule (whole-model `-acc` crashes FMS I/O at init).

---
[![cobalt CI](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml/badge.svg?branch=dev%2Fcefi)](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml)
