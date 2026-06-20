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
- **Compute:** explicit **`!$omp target teams loop collapse(3)`** (portable — macro-wrap to
  `target teams distribute parallel do collapse(3)` for AMD/Intel). We *measured* (see **Measured findings**
  below) that bare `do concurrent` auto-parallelization on nvfortran 24.11 is **context-sensitive and
  unreliable**: it under-parallelizes complex loop bodies, and even silently *regresses* a previously-full
  loop when unrelated code is added to the same file (§1.1 went grid 9,600→75). `collapse(3)` forces the
  full launch **deterministically**. Always confirm grid size / occupancy with `ncu`.
- **Data residency:** a thin **OpenMP-target** layer — map state once (`!$omp target enter data map(to:)`),
  per-call `target update` only for data crossing the CPU/GPU boundary; compute loops carry **no** map clause.
- **Memory model:** `-gpu=cc90,mem:separate` (no managed/unified auto-migration) — matches the dycore.
- **Reproducibility:** `-Mnofma` (bit-reproducible arithmetic; transcendentals validated by ensemble).

## Measured findings — why we use explicit `collapse(3)` (controlled profiling A/B)
We ran a controlled A/B/C on **§1.1** (nutrient limitation): *identical* loop body and *identical* thin
OpenMP data layer, varying **only** the compute construct, each profiled in the real no-MPI model
(128×128×75). This is our **own evidence** for the construct choice, not an assumption inherited from
the literature.

**Compute axis (`ncu`) — the three portable constructs are identical:**

| construct | grid×block (threads) | regs | theo. occ | achieved | SM % | kernel |
|---|---|---|---|---|---|---|
| `do concurrent (k=,j=,i=) local()` + `-stdpar=gpu` | 9600×128 (**1.23M**) | 72 | 43.75% | 43.6% | 64.1% | 8.0 ms |
| `!$omp target teams loop collapse(3)` | 9600×128 (**1.23M**) | 72 | 43.75% | 43.5% | 64.1% | 8.0 ms |
| `!$omp target teams distribute parallel do collapse(3)` | 9600×128 (**1.23M**) | 72 | 43.75% | 43.5% | 64.1% | 8.0 ms |

In *isolation* the three constructs compile to the same kernel — **but that equivalence is fragile.**

**§1.2 finding — `do concurrent` is context-sensitive and unreliable (the decision-changer).** When the §1.2
Geider growth loop was added to the same file and we re-profiled (`ncu`):
- the **complex Geider body** under-parallelized as bare `do concurrent` (nvfortran collapsed only `k` →
  **grid 75 / 6.25% occ**, j serialized); and
- the **§1.1 loop above it silently *regressed*** from its isolated grid 9,600 / 43.7% to **grid 75 / 6.25%**
  — *same source, only because unrelated code changed in the file*.
- Explicit **`collapse(3)` restored both deterministically** (§1.1 → grid 9,600 / 43.5%, kernel 80→8 ms; Geider → grid 9,600 / 18.7%).

**Decision (revised): use explicit `!$omp target teams loop collapse(3)`** for the COBALT kernels — `do
concurrent` auto-parallelization is too compiler-/context-dependent to rely on. Still portable (macro-wrap to
`target teams distribute parallel do` for AMD/Intel); the OpenMP-target data layer is unchanged.

### §1.2 Geider growth — full `collapse(3)` vs `do concurrent` evaluation (the evidence)
Geider growth loop (3-D pointwise × phyto × ecotype, `exp`-heavy), 128³, H100. **Provenance:** kernel TIME
from **`nsys`** (true GPU time); all SOL/occupancy/registers/IPC/warp metrics from **`ncu --set full`**;
growth wall-clock from the in-model **`mpp_clock`** timer; b2b from the model tracer totals; SASS from **`cuobjdump`**.

| metric (source) | `do concurrent` | `collapse(3)` | winner / why |
|---|---|---|---|
| Compute SOL % (ncu) | 6.33% | **31.77%** | cc3 5× — roofline dot moves up toward the compute roof |
| Memory SOL % / DRAM % (ncu) | 0.48% / 0.03% | 2.43% / 0.17% | both ~0 → **not memory-bound** |
| L1 / L2 hit % (ncu) | 96 / 96 | 95 / 95 | cached → kernel is **compute/latency-bound** |
| Grid (ncu) | 75 blocks | **9,600 blocks** | cc3 — fills the 132 SMs |
| Achieved occupancy (ncu) | 6.25% | **18.74%** (= theoretical) | cc3 3× — balanced launch |
| Active warps / SM (ncu) | 4.0 | **12.0** | cc3 3× latency-hiding |
| IPC active / issue-slots (ncu) | 0.26 / 6.4% | **0.75 / 18.9%** | cc3 ~3× useful work/cycle |
| Warp cycles / inst (ncu) | 15.5 | 15.9 | tie — ~14 cyc on a fixed-latency FP dependency |
| Registers / thread (ncu) | 144 | 130 | ~tie — **the win is NOT registers** |
| Geider kernel time (**nsys**) | **272 ms** | **54 ms** | cc3 **5×** |
| growth timer CPU→GPU (**mpp_clock**) | 73.5 → 27.0 s | 73.5 → **23.1 s = 3.18×** | the outcome |
| b2b (tracer totals) | within-band PASS | within-band PASS | correctness held |

**Why `collapse(3)` is better (mechanism):** the kernel is **arithmetic-latency-bound** — `ncu` reports
`Warp Cycles/Inst ≈ 15.5` *"stalled on a fixed-latency execution dependency"* (the `exp`/FP chains), with
DRAM ~0% and L1/L2 ~95% (so **not** memory-bound). That latency is hidden by **more warps in flight**. Bare
`do concurrent` launched only 75 blocks → 4 warps/SM → can't hide it (Compute SOL 6%, IPC 0.26). `collapse(3)`
launches 9,600 blocks → 12 warps/SM → hides it 3× better → Compute SOL 5×, IPC 2.9×, **kernel 5× faster**.
Per-warp latency and register count are ~unchanged — the win is **occupancy/parallelism**, confirmed on every
utilization axis with **no metric regressing**. Remaining headroom: occupancy is **register-capped at 18.75%**
(130 regs) → next lever is registers→~64 via `launch_bounds` / kernel-split.

### §1.3 nutrient uptake (N/P/Fe/Si) — 4 `collapse(3)` kernels (§1.2b step-1)
Ported as its own resident block. **A real bug the b2b caught (not round-off):** 4 outputs written for only
*some* indices — `juptake_n2` (DIAZO-only), `juptake_sio4`/`jdissloss_si`/`q_si_2_n` (diatom LARGE/MEDIUM-only)
— were mapped `alloc:`, so the un-written phyto indices got **uninitialized device garbage** → b2b **1e-4 rel
@4×4, crash @128³**. Fix: map them **`to:`** (carry prior host values); only fully-written-before-read fields
are safe as `alloc:`, and accumulators (`jprod_*`/`jo2resp_wc`) must be `to:` too. After the fix → **within-band
PASS** (CPU bit-identical to ref). *The conservation-protected totals b2b caught this; a smaller version could
slip through → argues for field-level b2b later.*
- **ncu:** all 4 kernels grid 9,600, **48–50 regs → 53–60% achieved occupancy, 75–81% SM throughput** — the
  best-utilized kernels so far (low register pressure). **nsys:** ~5 ms total (N 2.4/P 1.0/Fe 0.9/Si 0.7 ms).
- **But §1.3 was 367 ms on CPU and growth only dropped 23.1→20.1 s** — its **own-scope transfer (~110 ms/call)
  ate most of the win** → the motivation for **step-2: consolidate §1.1+Geider+§1.3 into one residency scope**
  so intermediates stay resident instead of round-tripping.

**Residency axis (`nsys`) — the kernel is not the cost; the per-call transfer is.**
§1.1 with per-call `enter/exit data` (1-coupling-step run, 2 COBALT calls):

| operation | time | vs kernel |
|---|---|---|
| GPU kernel (2 × 4.96 ms) | 9.9 ms | 1× |
| memcpy **Device→Host** (outputs back) | 170 ms | **~17×** |
| memcpy Host→Device (inputs) | 17.6 ms | ~1.8× |
| device + host allocation | ~32 ms | — |

Per call ≈ **5 ms kernel inside a ~95 ms transfer envelope** (dominated by copying §1.1's 33 output arrays
back to host). This is why **§1.1 in isolation is ~2% *slower* than CPU** (growth 72.7 s → 74.2 s; total
617 s → 637 s on the 128³/12-step case) despite an efficient kernel.

**Two tools, two truths:** `ncu` says *"efficient kernel — 64% SM, full occupancy"*; `nsys` says *"that
kernel is a rounding error next to the transfer."* Only together do they identify the real lever:
**residency, not the kernel.** → Port in **residency groups** (map tracers once; keep intermediate outputs
on-device for the downstream sections that consume them) rather than thin isolated slices.

### §1.2b Loop A — irradiance/photoacclimation (COLUMNAR): a structurally GPU-bound kernel, ported for residency
Loop A is the hardest loop in the growth block: per water-column `(i,j)`, a **sequential depth `k`-loop**
that carries state down-column (light attenuation = a prefix product; mixed-layer integrals + a
data-dependent boundary `kbl`). Restructured single-source for GPU: `collapse(2)` over (j,i), k sequential;
per-thread private scratch (`irr_band_loc(nbands)`, `pcmlim_ML(NUM_PHYTO)`, `sfc_irr_loc`, `kbl` — the
shared band-array and the `tmp_pcmlim_aclm_ML` accumulator would otherwise **race** across columns);
`day_of_year`/angles hoisted; `(1:kblt)` array-sections → explicit `do k=1,kbl`. **Provenance:** TIME from
`nsys`, all SOL/occupancy/registers from `ncu --set full`, growth wall from `mpp_clock`, b2b from totals.

| metric (source) | value | reading |
|---|---|---|
| b2b | within-band PASS (dic ~3 ULP; CPU bit-identical to ref) | A adds exp+trig → within-band, not bit-identical (expected) |
| Grid (ncu) | **128 blocks (16,384 threads)** | only the columns are parallel; depth is a recurrence |
| Achieved occupancy (ncu) | **6.25%** | grid-starved (~1 block/SM) — **structural ceiling**, not tunable |
| Registers (ncu) | 255 (hw max) | 2nd ceiling (theo occ 12.5%), but grid is the *binding* one |
| Compute / Mem / DRAM SOL (ncu) | 10.6% / 0.76% / 0.46% | latency-bound, not memory-bound (L1/L2 ~80/65%) |
| kernel time (nsys) | **7.68 ms** | modest — 10.7% of GPU kernel time (Geider still 75%) |
| growth timer (mpp_clock) | 20.1 → **18.1 s** = **4.07×** | A on GPU moved the needle |

**Key finding — A *cannot* fully utilize the GPU, and that's correct/accepted.** Saturating an H100 needs
~270,000 resident threads; A offers only 16,384 (the columns). The dimension that would fill it (75 depth
levels) is an **inherently sequential recurrence** (attenuation scan + dynamic mixed-layer boundary) — the
classic "tall-skinny column" class (cf. tridiagonal / vertical-mixing solves). Forcing full occupancy needs a
cooperative per-column block-scan rewrite that breaks single-source portability and maintainability — **not
worth it for a 7.68 ms / 2.6% loop**. We port A for **residency** (remove a CPU island so the whole growth
block can go single-scope), **not** for A's own speed. Low occupancy here is the expected, accepted outcome.

> **Why this matters for later:** A was a CPU island *in the middle* of the growth block, forcing host↔device
> bridges around it. With A (and soon B/E/F) on-device, the block can become **one residency scope** — map the
> growth working set in once, run §1.1→A→Geider→E→§1.3 back-to-back on the device, copy out once — which is
> what finally removes the per-section transfer tax (§1.1: 5 ms kernel in a 95 ms transfer envelope; §1.3: win
> eaten by ~110 ms own-scope transfer). Residency ≠ occupancy: it keeps the GPU *busy end-to-end* (no transfer
> stalls), it does not raise any single kernel's occupancy. This is the on-ramp to the MOM6 RESIDENT endgame
> (tracers resident across all of COBALT / the timestep).

### §1.2b COMPLETE compute coverage — the COMPUTE-vs-TRANSFER time budget (the port-level diagnostic)
Per-kernel occupancy answers *"is each kernel efficient";* the **time budget** answers *"is the PORT efficient"* —
different questions. Comprehensive `nsys` budget of the current **10-kernel** build (128³, per growth-call =
totals ÷2 for the 2 calls/step):

| component | time/call | volume / count | source |
|---|---|---|---|
| **Kernel compute** (Σ all 10) | **103 ms** | — | cuda_gpu_kern_sum |
| **DtoH transfer** | **214 ms** | 1.50 GB, **141 copies** | cuda_gpu_mem_time/size |
| **HtoD transfer** | **159 ms** | 1.89 GB, **696 copies** | cuda_gpu_mem_time/size |
| **Stream sync (host blocked)** | 103 ms | 95 syncs | cuda_api_sum |
| device alloc / launch | ~5 / 0.2 ms | ~60 allocs / 10 launches | cuda_api_sum |

**Diagnosis: the port is transfer/overhead-bound, NOT compute-bound.** Compute : transfer ≈ **1 : 3.6**;
compute is ~22% of GPU-active time, ~7% of the ~1.43 s/call growth wall. **Smoking gun: 837 memcpy ops +
~3.4 GB + ~95 syncs per call** — not the working-set size, but **redundant re-mapping**: 10 separate
`enter/exit data` scopes each re-map the common `cobalt`/`phyto` derived types (every allocatable component =
its own copy + pointer-attach → 696 HtoD ops) and each forces a sync. The ~0.95 s/call gap between GPU-active
(476 ms) and wall (1.43 s) is host-side residency management (issuing 837 maps + 95 syncs across 10 scopes).
→ **The MERGE (10 scopes → 1, map once in / once out) is the single highest-leverage remaining change**, and
the per-section wins were *capped by this overhead by construction*. **Lesson: pull the compute-vs-transfer
budget as a standard per-port diagnostic — kernel occupancy alone hides a transfer-bound implementation.**

**Checkpoint (commit a98f759):** growth-block compute coverage COMPLETE — §1.1, A, B, Geider, E, F,
§1.3(N/P/Fe/Si) on GPU; nh3 on CPU (free island). Cumulative growth CPU 73 s → GPU ~17 s = **4.2×**, but
transfer-bound per the budget above. **Next = the merge**, then the final gatekeeper (full b2b + budget
before/after + Tier-2 `-O2` production-CPU A/B).

## The baseline — TWO pinned cases (correctness vs speed are separated)
Both builds are the *same source*, no-MPI, single-PE, differing only in how `generic_COBALT.o` is compiled:
- **CPU build** (`nvhpc-x86-cpu-nompi`): `generic_COBALT.o` CPU-only (`do concurrent`→serial, `!$omp target` ignored), `-O0 -Mnovect -Mnofma -i4 -r8 -byteswapio`. 0 MPI / 0 CUDA symbols.
- **GPU build** (`nvhpc-x86-sep-nompi`): `generic_COBALT.o` + `-stdpar=gpu -mp=gpu -gpu=cc90,mem:separate`.

### Case A — b2b / correctness: `OM4.single_column.COBALT` (4×4×75, DT=900, `input.nml_48hr`)
A CI-validated coarse case, **stable for 48 hr = 2 full diurnal cycles** (exercises every COBALT branch:
photoacclimation, daylength, mixed-layer averaging). Runs in **~32 s**. Correctness is grid-size-independent
(COBALT is pointwise/columnar), so this validates the *same kernels* as the full grid.
- **CPU reference (saved in `ref_cpu_48hr/`):** restart `MOM.res.nc` + tracer inventory totals at the
  **default production config (`KD = 1.5e-5`, from `MOM_input`)** —
  `dic 1.5036917557803020e13 · alk 1.6266596567821816e13 · no3 1.1316293002204030e11 ·
  po4 7.5339387331740561e9 · o2 1.6808058953017490e12`.
  *(Rebuilt 2026-06-19 from byte-verified pristine source — the CPU baseline is 0 GPU / 0 OpenMP, confirmed
  at source + makefile + build-log + binary level. An earlier reference was inadvertently taken at
  `KD = 5.0e-4` — 33× the default — and is corrected here.)*
- **Round-off band (11-member ensemble, `KD·(1+k·1e-13)` at the default `KD = 1.5e-5`):** rel-range
  **dic 7.8e-16 · alk 4.8e-16 · no3 8.1e-16 · po4 5.1e-16 · o2 4.4e-16** → noise floor **~1e-15 (last 1–2 ULP)**.
- **b2b PASS criterion:** GPU tracer totals within **~1e-15 relative** of the CPU reference (≈15–16 sig figs).
  exp-block last-ULP differences land inside this band → validated as round-off; anything outside = a bug.

### Case B — speed / profiling: `OM4.scale128.COBALT` (128×128×75, DT=120, **12 steps**)
Realistic problem size for occupancy/roofline. **Speed-only** — this IC is a ~12-min smoke test and goes
free-surface-unstable (SSH→195 m) beyond ~2 hr at *any* DT, so it must **not** be used for b2b.
- **Speed (no-MPI, H100, 12 steps) — clean per-section measurement of §1.1 alone:** the §1.1-only port is
  **transfer-bound, not a speedup**: `Cobalt: phytoplankton growth` **CPU 72.7 s → GPU 74.2 s (~2% _slower_)**;
  total runtime **617 s → 637 s**. The §1.1 kernel is fast (~5 ms/call, 43.7% occ) but the per-call
  host↔device round-trip (~95 ms/call — see Measured findings) dominates. *(The earlier "3.3× / 21.9 s" figure
  was a different, more-complete **ad-hoc** port — not comparable to a single validated section.)* A real
  speedup needs **residency grouping**, not more isolated kernels.

Each section PR **pins the baseline commit + both test cases + step counts** so the comparison is reproducible.

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
- [ ] **CPU no-regression** — the single source must not hurt the CPU build:
  - *Tier 1 (every section, free):* the CPU exe's growth timer (already printed by the speed test) within **±5%** of the pre-change value. NOTE this is the `-O0 -Mnovect` reproducibility build → insensitive to restructuring, catches only **gross** regressions. (Our `!$omp target` directives are pure comments on CPU — 0 host-OpenMP symbols — so the construct change is a CPU no-op; real loop *restructuring* is what this guards.)
  - *Tier 2 (one-time, at the §-block merge — the real test):* build the **original** and the **restructured** source at **`-O2`** and compare the growth timer → certifies the GPU restructure didn't hurt *production* (optimized/vectorized) CPU. `-O2` is **not** bit-identical to the `-O0 -Mnofma` reference (FMA + reassociation legitimately change the last ULP) and we do not require it to be — we only sanity-check the `-O2` result lands **within the round-off band** of the reference (confirms optimization re-rounded, didn't expose a real hazard).
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
| §1.1 nutrient lim | 3491 | `omp target teams loop collapse(3)` | ✅ bit-identical (0.00e+00 vs ref) | ncu: grid 9,600 / 43.5% occ / 64% SM / 8 ms (do-concurrent regressed to grid 75 in-context → switched to collapse3) | ◑ kernel optimal |
| B light attenuation | 3656 | `do concurrent(j,i) local()` | aggregate only | yes — 255 regs, local-mem spill | ❌ |
| C acclimation | 3756 | `do concurrent(k,j,i)` | aggregate only | yes — under-parallelized | ❌ `collapse(3)` pending |
| §1.2a Geider growth | 3800 | `omp target teams loop collapse(3)` | ✅ within-band PASS (exp/MUFU.RCP, 2–3e-16) | nsys: 272→54 ms (5×); ncu: grid 9,600 / 18.7% occ / 31.8% SM; growth 73.5→23.1 s (**3.18×**) | ◑ reg-capped 18.75% → launch_bounds/split next |
| §1.3 uptake N/P/Fe/Si | 3924–4009 | 4× `omp target teams loop collapse(3)` | ✅ within-band PASS (Fe `exp`; CPU bit-identical). **Bug caught+fixed:** partial-write outputs were `alloc:` → device garbage (b2b 1e-4 @4×4, crash @128³) → changed to `to:` | nsys: 4 kernels **~5 ms total** (N 2.4/P 1.0/Fe 0.9/Si 0.7); ncu: grid 9,600 / 48–50 regs / **53–60% occ / 75–81% SM** (best-utilized yet); growth 23.1→20.1 s = **3.64×** | ◑ kernels optimal; **own-scope transfer ~110 ms/call** → consolidate (§1.2b step-2) |
| §1.2b Loop A irradiance (COLUMNAR) | 3639 | `omp target teams loop collapse(2)` over (j,i), k sequential | ✅ within-band PASS (exp+daylength trig; dic ~3 ULP; CPU bit-identical) | nsys: **7.68 ms**; ncu: **grid 128 (16,384 thr) / 6.25% occ / 10.6% SM / 255 regs** — structurally grid-bound (only columns parallel; depth is a recurrence); growth 20.1→18.1 s = **4.07×** | ◑ structurally capped — **NOT a defect**; ported for residency, not speed (see note) |
| §1.2b Loop B `f_irr_aclm`/`f_pcmlim_aclm` relax | 3746 | `omp target teams loop collapse(3)` | ✅ **bit-identical to prior GPU** (pure arithmetic) | nsys 1.02 ms; ncu: grid 9,600 / 74 regs / **36.9% occ / 56.5% SM** (healthy pointwise) | ✅ optimal |
| nh3 diagnostic | 3752 | **kept on CPU (free island — by design)** | n/a (CPU) | reads `f_nh4`/`temp`/`salt`/`f_htotal` (none modified by growth kernels → host valid) + writes `f_nh3` (consumed only by a later CPU section, line ~4097) → **no resident array touched → no bridge forced**, even in the merge. Has a `calc_pka_nh3` function call + `10**`/`log10` → porting needs `declare target` for **zero residency gain** → leave on CPU. | ✅ decision recorded |
| §1.2b Loop E ML growth-avg (COLUMNAR) | 3881 | `omp target teams loop collapse(3)` over (j,i,n), k seq | ✅ **bit-identical to prior GPU** (pure arithmetic, no transcendentals) | nsys 28.1 ms (2nd-biggest); ncu: **31.1% occ (5× A — n-dim parallelism), 90 regs, register-limited**; warp-cyc/inst 56.8 → **divergence-bound** (variable mixed-layer depth) | ◑ correct; divergence is a future tuning candidate |
| §1.2b Loop F `f_mu_mem` relax | 3896 | `omp target teams loop collapse(4)` | ✅ bit-identical to prior GPU | nsys 1.48 ms; ncu: 37% occ, 58% SM (healthy pointwise) | ✅ optimal |

*Ported so far = the growth pathway §1.1+§1.2 ≈ 10% of the 4,000-line reaction network. All rows above
predate this methodology and must be re-run through the loop from the clean baseline. Remaining big
targets: carbon chemistry / CO₂-pH solver (#1 CPU cost), zooplankton, production, remineralization.*

## Deferred optimizations (backlog — revisit by profile, not by default)
Levers we identified but **intentionally deferred** (rule: optimize the *measured* bottleneck, not the
interesting one). Recorded here so they survive context/`/scratch5` purges. Revisit only when the trigger fires.

| section | deferred lever | evidence (tool) | expected payoff | priority / revisit trigger |
|---|---|---|---|---|
| §1.2a Geider | registers 130→~64 (`launch_bounds` / `maxregcount` / split the ecotype `m`-loop) to lift the **18.75% register-capped occupancy** | ncu: occ register-capped; latency-bound (warp-cyc/inst ~15.5, DRAM ~0%) | **modest** — Geider is only ~3% of the GPU growth timer now (~0.2 s) | **LOW** — only if Geider re-surfaces as the bottleneck after §1.2b; watch for register **spills** (cuobjdump) |
| §1.2b Loop E (ML-avg) | reduce warp divergence from variable mixed-layer depth (`kbl`) — e.g. sort/bin columns by ML depth, or split the data-dependent accumulation | ncu: warp-cyc/inst 56.8, ncu "load imbalance — highly different durations per warp"; 28 ms (2nd-biggest kernel) | **moderate** — E is ~28 ms of the GPU growth | **MED** — revisit if E surfaces as the bottleneck after Geider; divergence is inherent to the columnar ML algorithm |
| §1.1 + §1.2a | **residency consolidation** — both still use *per-call* `enter/exit data` (~170 ms/call transfer; ncu DtoH ~155 ms/call dominates) | nsys | **HIGH** | **scheduled** — folds into §1.2b full growth-block residency (map once, copy back once) |
| growth (all) | **endgame: whole-COBALT residency** — map tracers once/timestep; keep growth outputs on device for the CPU foodweb/chem sections instead of copying back | nsys: output DtoH remains even after block residency | **HIGH** (removes inter-section transfer) | after growth + carbon + zoo are ported |
| §1.1 | 72-reg → 43.75% occ ceiling, but already 64% SM throughput | ncu: kernel optimal | negligible | none (kernel optimal) |

**Current measured priority (post-§1.2a):** the GPU growth timer (1,925 ms/call) is ~88% the **still-on-CPU
loops** (A irradiance / E ML-avg / §1.3 uptake), ~9% transfer, ~3% Geider kernel → **§1.2b (port A/E/§1.3 +
full-block residency) is the high-value next step**, not the Geider register tune.

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
