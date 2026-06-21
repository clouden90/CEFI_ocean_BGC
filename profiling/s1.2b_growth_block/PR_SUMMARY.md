# §1.2b: Phytoplankton growth block → GPU (single resident region)

Ports the **entire COBALT phytoplankton-growth block** (`generic_COBALT.F90`, the `(Cobalt: phytoplankton growth calcs)` timer, §1.1 + §1.2 + §1.3) to the GPU as **one residency region**, using the portable MOM6-aligned approach: `!$omp target teams loop collapse(N)` compute + a thin OpenMP-target data layer on `-gpu=cc90,mem:separate`, single-source (CPU and GPU from the same code), `-Mnofma` reproducible.

**Net result:** growth-block compute **CPU 72 s → GPU 16.6 s = 4.33×** (128×128×75, 12 steps, H100); coupled total 612 → 572 s. Bit-faithful (b2b within round-off of the CPU reference; CPU build bit-identical to reference). 10 kernels, one map-in / map-out per call.

---

## 0. Approach — how the loops were ported (the technique)

**Compute construct.** Each CPU loop nest gets an explicit `!$omp target teams loop collapse(N)` directive
(N = parallel dims); inner per-element loops (phyto `n`, ecotype `m`) stay sequential under `private(...)`. We
use *explicit* `collapse(N)` — **not** `do concurrent` — because nvfortran 24.11's do-concurrent
auto-parallelization is context-sensitive (§3d). Portable: macro-wrap to `target teams distribute parallel do
collapse(N)` for AMD/Intel. Pointwise example (§1.3 N-uptake):
```fortran
!$omp target teams loop collapse(3) private(n)
do k=1,nk ; do j=jsc,jec ; do i=isc,iec
   ... juptake_*(n) for n = 1..NUM_PHYTO ...
enddo ; enddo ; enddo
```

**Columnar loops (A irradiance, E ML-average) — the hard case.** Parallelize over `(j,i)` only; the depth
`k`-loop is a **sequential recurrence** (light attenuates down-column; mixed-layer accumulation with a
data-dependent boundary `kbl`). Restructured single-source so it's correct on CPU *and* GPU:
- per-thread **`private` scratch** (`irr_band_loc(nbands)`, `pcmlim_ML(NUM_PHYTO)`, `kbl`) — the original
  shared band-array and the `phyto%tmp_*` derived-type accumulators would **race** across columns;
- **hoist** the subroutine call out of the kernel (`day_of_year()` computed once above the loop — no calls inside a kernel);
- `(1:kblt)` array-section writes → explicit `do k=1,kbl` loops.

**Residency (data layer).** A thin OpenMP-target layer keeps the working set on-device: **one**
`!$omp target enter data map(to:/alloc:)` before §1.1, all 10 kernels run back-to-back (intermediates stay
resident — no host round-trips), **one** `exit data map(from:/delete:)` after §1.3. `mem:separate` (no managed
memory, for portability/control). Two correctness rules learned here: **partial-write & accumulator arrays
must be `map(to:)`** (carry prior host values — `alloc:` gives device garbage); and host code that writes a
mapped array mid-block needs a `target update` bridge (only `mld_aclm` here). The nh3 diagnostic stays a CPU
island (touches no resident-modified array → no bridge).

**Process (per section, gated).** PORT one loop → **b2b gate** (CPU bit-identical to ref; GPU within round-off)
→ PROFILE (`nsys` + `ncu` + `cuobjdump` on the real no-MPI model) → TUNE if the profile shows a fixable
bottleneck → re-b2b. Sections ported in order (§1.1 → A → B → Geider → E → F → §1.3), then the per-section
residency scopes **merged** into one. Every number is archived (§7). Full methodology/status in `GPU_PORTING.md`.

## 1. What's on the GPU

| section | loops | construct | b2b |
|---|---|---|---|
| §1.1 nutrient limitation | 1 | `collapse(3)` | bit-identical |
| §1.2 Loop A irradiance (columnar) | 1 | `collapse(2)`, k sequential | within-band |
| §1.2 Loop B relaxation | 1 | `collapse(3)` | bit-identical |
| §1.2 Geider growth rate | 1 | `collapse(3)` | within-band |
| §1.2 Loop E ML-average (columnar) | 1 | `collapse(3)`, k sequential | bit-identical |
| §1.2 Loop F relaxation | 1 | `collapse(4)` | bit-identical |
| §1.3 nutrient uptake N/P/Fe/Si | 4 | `collapse(3)` | within-band |
| §1.2 nh3 diagnostic | — | **CPU free island** (reads unmodified `f_nh4`, writes unconsumed `f_nh3` → no bridge) | n/a |

All 10 kernels share **one** `enter data … exit data` scope (intermediates resident on-device); the only mid-block host write to a mapped array (`mld_aclm`) is handled with a single `target update to()` bridge.

## 2. Correctness (b2b)

Two-tier gate, per `GPU_PORTING.md`:
- **Pure-arithmetic loops** (§1.1, B, E, F) → **bit-identical** to the CPU reference *and* to the prior GPU result.
- **Transcendental loops** (A: `exp`+trig; Geider, §1.3-Fe: `exp`) → **within the round-off band** (last-ULP `MUFU` vs CPU `libm`), documented.
- **CPU build bit-identical to the committed reference** every step → single-source guarantee intact.

Final merged-build b2b (4×4×75, 48 hr = 2 diurnal cycles, default `KD=1.5e-5`):

| tracer | \|GPU−ref\|/ref | round-off band | verdict |
|---|---|---|---|
| dic | 6.5e-16 | 3.9e-16 | PASS |
| alk | 3.6e-16 | 4.8e-16 | PASS |
| no3 | 1.4e-16 | 2.7e-16 | PASS |
| po4 | 1.3e-16 | 6.3e-16 | PASS |
| o2 | 2.9e-16 | 1.0e-15 | PASS |

PASS criterion is **within `max(4×band, 1e-13)`**, not the raw round-off band: `dic` at 6.5e-16 (~3 ULP, slightly above its 3.9e-16 band) reflects Loop A's *many* transcendentals (`exp` + daylength `atan/asin/acos`) and is well within the 1e-13 acceptance tolerance — expected, not a regression. The merge + cleanup were each re-verified **bit-identical to the prior GPU result** (pure refactors).

> This branch also **corrected the b2b reference** to the default config (`KD=1.5e-5`) — hence the `gpu_b2b_ref/` changes in the diff. The reference is the no-MPI CPU build's tracer totals, regenerated from trusted pristine source.

## 3. Performance — full profiling record

**Provenance:** kernel TIME from `nsys`; SOL/occupancy/registers/IPC/warp-stalls/roofline from `ncu --set full`; growth wall from the in-model `mpp_clock`; b2b from tracer totals; SASS from `cuobjdump`. Profiled in the **real no-MPI model** (the coupled model built without MPI so `ncu` profiles the in-model kernels directly).

### 3a. Whole-block time budget — before → after the merge (per growth-call, 128³)

| metric | 10 separate scopes | one merged scope | change |
|---|---|---|---|
| kernel compute | 103 ms | 103 ms | unchanged |
| stream syncs | 95 | 28 | −70% |
| HtoD copies / bytes | 696 / 1.89 GB | 402 / 0.85 GB | −42% / −55% |
| DtoH copies / bytes | 141 / 1.50 GB | 137 / 1.45 GB | ~unchanged |
| transfer time | 373 ms | 331 ms | −11% |

*(Copies/bytes/syncs are **deterministic** — set by the map directives — and are the robust before/after evidence. Transfer **time** is run-to-run variable ~±10%; the values above are from the archived `budget.nsys-rep` / `mbud.nsys-rep` in `profiling/`.)*

### 3b. Per-kernel profile — all 10 kernels

| kernel | time (nsys) | grid | regs | occ. ach/theo | SM SOL% | DRAM% | IPC | warp-cyc/inst | bound |
|---|---|---|---|---|---|---|---|---|---|
| §1.1 | 4.9 ms | 9600 | 72 | 43.6/43.8 | 64% | 2.2 | 1.55 | 18.0 | instr/latency |
| A irradiance | 7.7 ms | 128 | 255 | 6.25/12.5 | 10.6% | 0.5 | 0.25 | 15.9 | grid-starved (columnar) |
| B relax | 1.0 ms | 9600 | 74 | 37/37.5 | 56% | 2.5 | 1.36 | 17.4 | healthy |
| Geider | 54 ms | 9600 | 130 | 18.7/18.8 | 31.8% | 0.17 | 0.75 | 15.9 | register-capped |
| E ML-avg | 28 ms | 65536 | 90 | 31.1/31.3 | 15.2% | 0.01 | 0.35 | 56.9 | divergence (columnar) |
| F relax | 1.5 ms | 38400 | 74 | 37/37.5 | 58% | 1.4 | 1.37 | 17.3 | healthy |
| §1.3 N | 2.4 ms | 9600 | 50 | 53/56 | 79% | 2.3 | 1.78 | 19.0 | healthy |
| §1.3 P | 1.0 ms | 9600 | 48 | 60/62 | 81% | 5.3 | 1.86 | 20.6 | healthy |
| §1.3 Fe | 0.9 ms | 9600 | 50 | 53/56 | 76% | 4.8 | 1.74 | 19.4 | healthy |
| §1.3 Si | 0.7 ms | 9600 | 48 | 60/62 | 81% | 6.0 | 1.86 | 20.5 | healthy |

### 3c. Roofline (DP-FLOPs / DRAM bytes)

| kernel | arithmetic intensity | achieved GFLOP/s |
|---|---|---|
| §1.1 | 2.14 FLOP/B | 175 |
| A | 2.51 FLOP/B | 42 |
| B | 0.20 FLOP/B | 18 |

**Interpretation:** every kernel sits **deep in the latency-bound region** — well below *both* the H100 FP64 compute roof (~34 TFLOP/s) and the HBM bandwidth roof (DRAM% all <7%). COBALT growth is **neither FP64- nor memory-bound**; it is **instruction-issue/latency bound** (transcendentals via `MUFU`, address calc, branches). Hence **SM-throughput SOL% is the meaningful utilization metric**, not FP64 GFLOP/s — and it cleanly explains the three non-ideal kernels (A grid-starved, Geider register-capped, E divergence-bound).

### 3d. Construct study — `do concurrent` vs explicit `collapse(3)` (measured, §1.1 + Geider)
On nvfortran 24.11, bare `do concurrent` auto-parallelization is **context-sensitive**. Measured Geider A/B (`08_construct…`, `ncu --set full`): bare `do concurrent` → **grid 75 / 6.25% occ / 6.33% SM / 448 ms**; explicit `collapse(3)` → **grid 9,600 / 18.74% occ / 31.77% SM / 90 ms ≈ 5×** (deterministic full launch). The §1.1 loop also silently regressed (grid 9,600→75) once the Geider loop was added to the same file — documented in `GPU_PORTING.md` (earlier construct test; its raw profile is not in this archive). **Decision: explicit `collapse(3)`** (portable — macro-wrap to `target teams distribute parallel do` for AMD/Intel).

### 3e. Speed
`(Cobalt: phytoplankton growth calcs)` timer, 128³/12-step, H100: **CPU 72–73 s → GPU 16.6 s = 4.33×**; coupled total 612 → 572 s.

## 4. CPU no-regression (single-source guarantee)
- **Tier-1** (`-O0` reproducibility build, every section): CPU growth timer flat at ~72–73 s, within ±5% → **PASS**.
- **Tier-2** (`-O2` optimized CPU, restructured vs pristine pre-GPU source): **PASS** — COBALT growth `-O2`: restructured **76.6 s** vs pristine **74.9 s** = **+2.2%, within run-to-run noise** → no meaningful optimized-CPU regression from the restructuring.
  - *Method note:* a whole-model `-O2` build **crashes at startup** due to an nvfortran `-O2` miscompile of the FMS namelist/table parser (`get_variable_line %CON`) — unrelated to the port (both restructured *and* pristine fail identically). Worked around with an **object-swap**: compile only `generic_COBALT.o` at `-O2`, relink against the `-O0` FMS (no parser bug), run. The restructured COBALT itself compiles cleanly at `-O2`.
  - *Finding:* `-O2` ≈ `-O0` for the growth block (~75 vs ~73 s) — these loops don't vectorize (derived-type/transcendental/columnar-recurrence), so the `-O0` reproducibility build costs ~nothing in CPU performance for this code.

## 5. Key findings (documented in `GPU_PORTING.md`)
1. **`do concurrent` is unreliable on nvfortran 24.11** → use explicit `collapse(3)`.
2. **alloc-vs-`to:` gotcha** — partial-write/accumulator arrays must be `map(to:)`, never `alloc:` (caught by b2b: garbage at 4×4, crash at 128³).
3. **Residency ≠ occupancy** — the merge removes per-call transfer waste; it doesn't change kernel occupancy.
4. **The remaining DtoH (~1.45 GB/call) is the GPU↔CPU boundary, not waste** — data-flow analysis shows every output (except `kblt`) is consumed by the still-CPU downstream; irreducible until those sections are ported.
5. Columnar loops (A, E) are structurally limited (A grid-starved at 16k threads; E divergence-bound) — ported for **residency**, not their own speed.

## 6. Next steps (recommended)
1. **Foodweb group** — production (~18 s), zooplankton (~16 s), other losses (~13 s), source/sink (~17 s) [archived `09_section_costs.txt`]: pointwise reaction kinetics (clean `collapse(3)` ports) that are the **immediate downstream consumers of growth's outputs** → porting them **extends the resident scope and shrinks the boundary DtoH**.
2. **Carbon chemistry** (CO₂/pH, ~40 s, #1 cost) — the big prize but **hardest** (iterative Newton solver → needs the fixed-iteration / host-driven GPU pattern); dedicated later effort.
3. **Whole-COBALT residency endgame** — once downstream is on-device, map tracers once per timestep so each output is produced *and* consumed on-device → the GPU↔CPU boundary (and its DtoH) **disappears**.
4. **Optional kernel tunes** (low priority, in backlog): Geider register-cap (`launch_bounds`/split, ~18.75% occ), E divergence (bin columns by mixed-layer depth).

## 7. Reproducibility
- No-MPI build recipe (serial FMS `_nocomm` + nvfortran) so `ncu` profiles the in-model kernels; build platforms `nvhpc-x86-sep-nompi` (GPU) / `nvhpc-x86-cpu-nompi` (CPU reference).
- b2b reference committed in `gpu_b2b_ref/` (ocean.stats + tracer totals + round-off band, default `KD=1.5e-5`).
- **Profiling artifacts archived in `profiling/s1.2b_growth_block/`** — clean text reports regenerated from the `.nsys-rep`/`.ncu-rep`, the raw b2b/speed/Tier-2/construct logs, the profiling sbatch scripts, and a `PROVENANCE.md` mapping **every number above → its file + re-extraction command**. All figures are re-derivable from committed artifacts (not hand-transcribed).
- Full methodology, status tracker, references, and the deferred-optimization backlog in `GPU_PORTING.md`.
