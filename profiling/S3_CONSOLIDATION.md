# §3 (ballast + source/sink + M2 region-merge) — consolidation results

Commits (all on fork `feature/gpu-s3-srcsink`): `18d7594` all-pointer · `95f1ab8` M2-loop2 · `6112c6e` M2-full.
Build: `nvhpc-x86-sep-nompi` (GPU, cc90, mem:separate). b2b: `OM4.single_column.COBALT.b2b`, 4×4×75, 48 hr, KD=1.5e-5.
Reproduce: `profiling/consolidate_tier12.sbatch` (Tier-1/2), `profiling/consolidate_prof.sbatch` (nsys+ncu).

## Correctness

**GPU 17-tracer b2b: PASS, bit-faithful** (worst 2.87e-14 < tol 1e-13) — GPU(M2) vs Tier-1 CPU reference.

**Tier-1 (-O0 CPU, rebuilt from M2 source): BIT-IDENTICAL** to the committed reference — confirms the whole
ballast+source/sink+M2 change is OpenMP-target-directive-only (CPU build ignores it):

| tracer | CPU(-O0, M2) | rel vs ref |
|---|---|---|
| dic | 1.5036917557803020e13 | 0.00e+00 |
| alk | 1.6266596567821816e13 | 0.00e+00 |
| no3 | 1.1316293002204030e11 | 0.00e+00 |
| po4 | 7.5339387331740561e9  | 0.00e+00 |
| o2  | 1.6808058953017490e12 | 0.00e+00 |

**Tier-2 (-O2 CPU): not attainable — the coupled model is broadly -O2-unstable under nvfortran 24.11, in
framework code unrelated to COBALT.** Full investigation (all crash at INIT, before the COBALT time loop):

| run | build flags | result |
|---|---|---|
| Tier-2  | `-O2 -Mnofma` (vectorized) | `FATAL get_variable_line: extra close block "%CON"` |
| Tier-2 (re-run) | same | **reproduces deterministically** → not a transient NFS glitch |
| Tier-2b | `-O2 -Mnovect -Mnofma` | same `%CON` crash → **vectorizer ruled out**; it's -O2 *scalar* opt |
| Tier-2c | `-O2`, `MOM_file_parser.o` @ `-O0`, relink | `%CON` **fixed**; now **segfaults in atmos-model init** (another file) |

Root cause: `get_variable_line` is in **MOM6's `MOM_file_parser.F90`** (the param-file parser), not field_manager.
nvfortran 24.11 `-O2` miscompiles it (and at least one more file in the atmos/coupler init path). All failures are at
INIT, before any COBALT code runs; none involve the port. This is exactly why the project pins its reproducible build
to `-O0 -Mnovect -Mnofma` (the GPU `sep` build and Tier-1 both use it for FMS/host code). Chasing each -O2 miscompile
file-by-file is open-ended framework debugging, out of scope for the port.

**Why this is not a correctness gap:** the port is OpenMP-target-**directive-only on the CPU build** (the CPU compiler
ignores the directives), and **Tier-1 proves the CPU result is BIT-IDENTICAL to the reference** — so -O2 of the ported
CPU code would be -O2 of the *original* code; any -O2 issue is pre-existing framework instability, not introduced here.
Optimized-compile coverage of the actual COBALT kernels comes from the **GPU `sep` build (b2b bit-faithful)**. Tier-1
(bit-identical) + GPU b2b (bit-faithful) are therefore the conclusive correctness gates; Tier-2 -O2 CPU adds nothing
the port could fail and is blocked by unrelated framework miscompiles regardless. Reproduce: `profiling/tier2_rerun.sbatch`,
`tier2b_O2novect.sbatch`, `tier2c_parser_O0.sbatch` (+ template `builds/nvhpc/x86-cpuO2nv-nompi.mk`).

## Performance

**Per-loop GPU timing (128³, 12-step) — M2 eliminates the source/sink re-HtoD** (loops read foodweb intermediates
resident, no per-loop reload):

| section | CPU | GPU all-pointer | GPU M2 |
|---|---|---|---|
| ballasting loops | 3.7 | 6.75* | 0.35 |
| source/sink loop2 | 4.7 | 0.90 | 0.63 |
| source/sink loop3 | 1.8 | 0.81 | 0.55 |
| source/sink loop5 | 1.5 | 0.53 | 0.34 |
| source/sink loop6 | 4.3 | 1.47 | 1.60 |

\*all-pointer ballast timer absorbed the exit-DtoH; M2 relocated it. Total wall ~513–516 s (within run noise) —
transfers are cheap in wall terms, so M2's win is transfer VOLUME, not wall.

**nsys transfer (M2 GPU exe, 128³, 1-step):** HtoD 3.5 GB / DtoH 9.5 GB, 27 distinct kernels launched (28 compiled;
do_resp_ca_diss + do_14c gated off). Higher than foodweb-only merge4 (2.3/7.0 GB) only because M2 now covers
ballast+source/sink+all p_* transfers; the re-HtoD elimination shows in the per-loop timing above (a clean nsys
before/after would require profiling the all-pointer `18d7594`).

**ncu occupancy (`--set basic`):** tuning candidates — `F1L3686` (growth) 255 reg/thread → 6.25% achieved occupancy
(register-spilled); several growth kernels register-limited (72–130 reg, 18–44% occ). Source/sink kernels in
`consol_ncu.ncu-rep`. Occupancy tuning is a future backlog item (register caps via `-gpu=maxregcount`/restructuring).

## Status: correctness consolidation COMPLETE — Tier-1 bit-identical + GPU b2b bit-faithful are the conclusive gates;
## Tier-2 -O2 CPU investigated and shown not attainable (unrelated nvfortran-24.11 framework -O2 miscompiles).
## Remaining: figures, PR (base feature/gpu, needs explicit go).
