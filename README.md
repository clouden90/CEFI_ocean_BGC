<!-- GPU-PORT-SECTION -->
# COBALT GPU Port — v2: `do concurrent` + OpenMP-target + separate memory

This branch ports the COBALT biogeochemistry reaction loops (`generic_COBALT.F90`) to GPU using a **portable, ISO-standard approach that aligns with the MOM6 dynamics-core GPU port**.

## Approach
- **Compute:** standard Fortran **`do concurrent`** (`-stdpar=gpu`) — one GPU thread per ocean cell. Same source compiles for CPU or any vendor's GPU (NVIDIA / AMD / Intel).
- **Data residency:** a thin **OpenMP-target** layer (`-mp=gpu`) on a **separate** CPU/GPU memory model (`-gpu=cc90,mem:separate`) — nothing auto-migrates, residency is explicit:
  - **map once** at first call (`!$omp target enter data map(to: …)`) — the tracer/state arrays stay resident the whole run;
  - **per call** only `!$omp target update to/from` for the data that crosses the CPU/GPU boundary;
  - compute loops carry **no `map` clause** (rely on "default present").
- **Why this over OpenACC:** OpenACC (see the sister branch) is NVIDIA-only and used a different (managed) memory model than the dynamics core. The memory model is a *whole-executable* setting, so the biology must match the dynamics. This branch rebuilds the port on the dynamics-core stack so the whole model shares **one portable GPU strategy**.

## Scope (so far)
Growth pathway fully on GPU: **§1.1 nutrient limitation + §1.2 light/growth (blocks B–G)** — 6 `do concurrent` kernels. The column-sequential blocks (light attenuation, mixed-layer averages) use `do concurrent(j,i)` with a `local()` private state and the depth loop kept sequential.

## Benchmark (H100 NVL · OM4 128×128×75 = 1.23 M cells · 6 COBALT calls)
| `Cobalt: phytoplankton growth` clock | time |
|---|---|
| CPU (`-O0`) | 39.18 s |
| §1.1 on GPU | 36.67 s |
| + §1.2 blocks C/E/F/G | 13.03 s |
| **+ block B (full §1.2 on GPU)** | **12.35 s — 3.2× on the block** |

- **Matches the OpenACC version** (12.35 s vs 12.74 s) while being vendor-portable.
- **Profile (Nsight Systems):** dominant kernel = Geider growth (57%, double-precision `exp`/`pow`, 144 regs → ~22% occupancy); #2 = mixed-layer average (28%) — *parallelism-starved* (49 K threads vs 1.2 M), the next optimization target.

## Correctness
- Pure-arithmetic blocks are **bit-for-bit identical** CPU↔GPU (e.g. step-24 `En = 2.3202667142135869e-5`).
- `exp`-based blocks can't be bit-identical (GPU/CPU round transcendentals differently). Validated with a **10-member CPU round-off ensemble**: the GPU result (`2.3202667142126203e-5`→`…133765e-5`) lands **inside** the natural noise band `[2.3202667142081781, 2.3202667142213410]e-5` — statistically indistinguishable from round-off (the method operational centers like ICON use).

## Build flags
```
# base (whole model, CPU):  -O0 -Mnovect -Mnofma -r8 -i4 -byteswapio
# generic_COBALT.o only:     -stdpar=gpu -mp=gpu -gpu=cc90,mem:separate -Minfo=accel,mp
```
`-Mnofma` gives the bit-reproducible arithmetic; the GPU flags are scoped to the one file via a target-specific make rule (whole-model offload crashes FMS I/O at init).

---
[![cobalt CI](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml/badge.svg?branch=dev%2Fcefi)](https://github.com/NOAA-CEFI-Regional-Ocean-Modeling/ocean_BGC/actions/workflows/cobalt_ci.yml)
