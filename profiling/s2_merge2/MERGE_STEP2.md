# MERGE step-2: zoo + losses + production fused into one residency region

Staged merge step 2 of 4. Extends the resident region upstream to include zoo: one enter before zoo →
4 kernels (zoo, losses-3D, losses-2D, production) back-to-back → vmove bridge → one exit after production.
Key reconciliation: zoo OUTPUTS that production consumes (`zoo%jingest_*`, `zoo%temp_lim`, `cobalt%hp_jingest_n/p`)
flipped `to:`→`alloc:` (produced in-region, resident); `hp_jingest_fe/sio2` stay `to:` (external).

## Correctness — b2b PASS (bit-faithful)
4×4×75, 48hr: dic 1.30e-16, alk 3.60e-16, no3 0, po4 2.53e-16, o2 1.45e-16 — all PASS, identical to every prior
run. The 3-way ~130-array union is correct (incl. the to:→alloc: flips). `05_b2b.txt`.

## Performance — transfer budget (deterministic; per-call)
| metric | pre (5 scopes) | step-1 | step-2 | step1→2 | cumulative |
|---|---|---|---|---|---|
| HtoD MB | 2996 | 2328 | **1918** | −17.6% | **−36.0%** (−1078 MB/call) |
| DtoH MB | 3642 | 3685 | 3685 | flat | +1.2% |
| syncs | 106 | 103 | **76** | −26.2% | **−28.3%** |

zoo+losses+production combined: CPU 42.7 s → GPU 7.4 s = **5.77×**.

## Finding (now confirmed over TWO merge steps)
The merge keeps reclaiming **HtoD** (cumulative −36%, −1.08 GB/call) and **sync count** (−28%) — exactly as
designed, deterministic. But **DtoH is flat** and the **wall does not improve**: the cuStreamSynchronize TOTAL
TIME is unchanged (~320M ns both steps), because the wall is bound by the one big exit DtoH (~3.6 GB/call) that
feeds the still-CPU downstream (source/sink, diag). That DtoH is irreducible until the downstream is on GPU.

**Conclusion:** the merge is correct, reclaims HtoD+syncs, and produces cleaner code (5 scopes → 1 region), but
the WALL win is gated by porting the downstream. Steps 3–4 (bacteria, growth) will reclaim more HtoD (growth is
the biggest flow) but the wall stays DtoH-bound until source/sink+diag are also resident.

Re-extract: `nsys stats --report cuda_gpu_mem_size_sum m2_budget.nsys-rep` (÷2); speed from `01_budget_speed.txt`.
