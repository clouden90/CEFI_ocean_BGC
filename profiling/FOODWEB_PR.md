# §2: COBALT foodweb → GPU + whole-region residency merge

Ports the **entire COBALT foodweb reaction network** to GPU and fuses it (with the already-merged §1.2b growth
block) into **ONE resident region**. Five sections on top of §1.2b: bacteria growth, zooplankton, other losses,
production, all via the portable MOM6-aligned pattern (`!$omp target teams loop collapse(N)` + a thin
OpenMP-target data layer on `-gpu=cc90,mem:separate`, single-source CPU+GPU, `-Mnofma` reproducible).

**Net result:** 5 foodweb sections on GPU (2.9–8.4×); the whole foodweb (growth→bacteria→zoo→losses→production,
**17 kernels**) runs as one resident GPU region; **HtoD −61%, syncs −42%** vs the per-section baseline; b2b
within round-off; CPU build **bit-identical** (Tier-1) and `-O2` unregressed (Tier-2). Honest scope: the
**wall-clock is flat** (~528 s) — bounded by the DtoH to the still-CPU downstream; this PR is the architecture +
HtoD groundwork, and the wall win is the next phase (port source/sink + diagnostics).

---

## 0. Approach
Same gated protocol as §1.2b, per section: PORT one section (`collapse(3)` pointwise; `collapse(2)` for the 2D
surface loop) → **b2b gate** (CPU bit-identical to ref; GPU within round-off) → PROFILE (nsys + ncu `--set full`
+ cuobjdump on the real no-MPI model) → TUNE if warranted → re-b2b. Then a **4-step staged residency merge**
(downstream→upstream), b2b-gated at each step, collapsing the 5 per-section scopes into one
`enter … 17 kernels … exit` region with 3 `target update` bridges. Two reusable, committed auditors:
`verify_s2.py` (every reported number == archive) and `verify_all.py` (metrics + figure-logic + source).

## 1. What's on the GPU
| section | kernels | construct | b2b |
|---|---|---|---|
| §1.2b growth (prior PR) | 10 | collapse(2/3/4) | bit-id / within-band |
| bacteria growth | 3 | collapse(3); `firstprivate(scheme_nitrif, vmax_bact)` | within-band |
| zooplankton | 1 | collapse(3); `firstprivate` scratch matrices (race-avoidance) | within-band |
| other losses | 2 | collapse(3) + collapse(2) surface | within-band (≈bit-id) |
| production | 1 | collapse(3) | **bit-identical** |
| **whole foodweb** | **17** | **ONE resident region** (1 enter / 1 exit / 3 bridges) | — |

Bridges: `mld_aclm` (host MLD), `f_nh3` (host nh3-island diagnostic → device), `vmove` (device → host for
`g_tracer_set_values`). The nh3 diagnostic stays a CPU island.

## 2. Correctness (b2b) — bit-faithful at every step + comprehensive 17-tracer gate
4×4×75, 48 hr, GPU vs cpu reference (CPU = Tier-1 bit-identical to pristine). The per-step gate (5 tracers,
within `max(4×band,1e-13)`) PASSED identically across all 4 ports + all 4 merge steps. A final **comprehensive
17-tracer b2b** then confirmed bit-faithfulness across **every foodweb currency** (not just C/N/P/O/alk):
| cycle | tracers | max \|GPU−CPU\|/\|CPU\| | verdict |
|---|---|---|---|
| carbon / N / P / O / alkalinity | dic, alk, no3, po4, o2 | 3.6e-16 | PASS |
| silica | sio4 | 1.4e-16 | PASS |
| dissolved iron | fed | 1.6e-16 | PASS |
| phytoplankton biomass | ndi, nlg, nmd, nsm | 2.9e-14 | PASS |
| zooplankton biomass | nsmz, nmdz, nlgz | 2.8e-15 | PASS |
| bacteria / detritus / labile DOM | nbact, ndet, ldon | 4.1e-15 | PASS |

All 17 within round-off (max 2.9e-14 ≪ 1e-13 tol). This exercises the silica/iron cycles and all biomass/
detritus/DOM pools that the 5-tracer gate only covered indirectly. (`s2_consolidation/b2b_17tracer_full.txt`)

## 3. Performance (128³, 12 steps, H100 NVL)
### 3a. Per-section speedup (mpp_clock, CPU vs GPU)
| section | CPU (s) | GPU (s) | speedup |
|---|---|---|---|
| bacteria growth | 1.34 | 0.46 | 2.88× |
| zooplankton | 14.58 | 1.74 | 8.37× |
| other losses | 11.99 | 2.81 | 4.27× |
| production | 16.54 | 2.11 | 7.84× |
| (growth, §1.2b) | ~73 | ~16 | ~4.4× |

### 3b. Per-kernel profile (ncu --set full; representative)
| kernel | nsys ms/call | grid | regs | SM-SOL% | note |
|---|---|---|---|---|---|
| bact-amx | 0.17 | 9600 | 48 | 79.0 | healthy |
| bact-nitrif | 0.52 | 9600 | 64 | 68.1 | healthy |
| bact-prod | 1.37 | 9600 | 90 | 49.4 | healthy |
| zoo | 28.6 | 9600 | 136 | 29.2 | register-capped (firstprivate scratch) |
| losses loop1 | 7.11 | 9600 | 56 | 75.4 | healthiest foodweb kernel |
| losses loop2 | 0.021 | 128 | 56 | 8.1 | grid-starved but NEGLIGIBLE |
| production | 19.1 | 9600 | 74 | 54.5 | healthy |

All latency-bound (low DRAM%, well below FP64/HBM roofs) — consistent with §1.2b. Attention report
(`figs/ATTENTION.txt`) flags zoo/Geider/A/E as the only tuning candidates by time.

### 3c. Residency merge — transfer budget (deterministic, per-call)
| metric | pre-merge (5 scopes) | merged (1 region) | change |
|---|---|---|---|
| HtoD | 3.0 GB | **1.16 GB** | **−61%** (−1.83 GB/call) |
| stream syncs | 106 | **61** | **−42%** |
| DtoH | 3.6 GB | 3.5 GB | ~flat |
| coupled GPU wall | — | ~528 s | flat |

## 4. CPU no-regression (single-source guarantee)
- **Tier-1** (`-O0`, rebuilt from §2 source): b2b PASS, CPU **bit-identical** to the pristine reference
  (CPU column == ref; `|GPU−CPU|` == `|GPU−ref|`). The GPU port left the CPU path untouched.
- **Tier-2** (`-O2`, object-swap, restructured vs pristine): all sections within ±3% run-to-run noise
  (carbon −0.3%, growth −0.9%, bacteria −0.6%, zoo +2.1%, losses +2.7%, production +1.2%) → no meaningful
  optimized-CPU regression. (Expected: the §2 diff is directive-only + empty loop-wrappers; CPU code byte-identical.)

## 5. Key findings
1. **`firstprivate` for shared per-cell scratch** (zoo's `ipa_matrix`/`ingest_matrix`/… that rely on host
   pre-loop init) — `private` would feed garbage; the b2b within-band shift confirmed the split is correct.
2. **alloc-vs-`to:` for cross-section accumulators** — every `+=` array carrying upstream values must be
   `to:`+`from:`; the staged merge made each section's reconciliation explicit and b2b-checkable.
3. **The merge reclaims HtoD + syncs, not the wall.** DtoH (~3.5 GB/call) dominates the wall and is **bounded by
   the still-CPU downstream** (source/sink, diagnostics) — it cannot shrink until those are ported. This PR is
   the necessary groundwork + max HtoD + clean one-region architecture; the wall win is the next phase.

## 6. Next steps
1. **Port source/sink + diagnostics** — the natural next extension that finally moves the wall: source/sink
   consumes the resident foodweb outputs (`cobalt%jprod_cadet/ndet/fedet`, `zoo%jprod_n`, …) and is pure
   arithmetic (→ bit-identical), so extending the region keeps those outputs resident and **collapses the
   ~3.5 GB DtoH**. Note this is substantial work, not a trivial edit: source/sink has ~45 host `g_tracer_set/get`
   calls and the diagnostics section is ~930 lines with ~43 diag-sends — those host interactions need careful
   bridge/island handling (diagnostics especially). The DtoH *payoff* is simple to reason about; the *port* is not.
2. **Carbon chemistry** (iterative pH/CO₂ Newton solver) — the hardest piece, dedicated later effort.
3. **Optional kernel tunes** (backlog): zoo register-cap (firstprivate spills), the §1.2b A/E/Geider items.

## 7. Reproducibility
- No-MPI build (serial FMS `_nocomm` + nvfortran) so `ncu` profiles in-model kernels; platforms
  `nvhpc-x86-sep-nompi` (GPU) / `nvhpc-x86-cpu-nompi` (CPU ref).
- Per-section profiling archived in `profiling/s2_{production,zoo,losses,bacteria}/`; merge in
  `profiling/s2_merge{1..4}/`; CPU tiers in `profiling/s2_consolidation/`; each with `PROVENANCE.md`/findings.
- `python3 profiling/verify_s2.py` → all reported §2 metrics match the archive; `python3 profiling/verify_all.py`
  → metrics + figure-logic + source all verified. Figures via `python3 profiling/make_figs.py <dir>`.
