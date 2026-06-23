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

**Tier-2 (-O2 CPU): aborted at init** — `FATAL: get_variable_line: extra close block ... %CON` (FMS field-table
parse), BEFORE COBALT runs. NOT an M2/numerical issue (Tier-1 with the same source parsed fine; -O2 source/sink
had never been run before). Environmental/parse glitch → clean re-run pending. Not a correctness blocker.

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

## Status: correctness consolidation COMPLETE (Tier-1 bit-identical + GPU b2b). Remaining: Tier-2 clean re-run,
## figures, PR (base feature/gpu, needs explicit go).
