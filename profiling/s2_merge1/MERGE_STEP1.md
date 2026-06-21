# MERGE step-1: losses + production fused into one residency region

Staged merge (downstream→upstream), step 1 of 4. Fuses the losses scope + production scope into ONE
`enter…exit` region: the losses→production intermediates (`phyto%j*loss_*`, `bact%jvirloss`, `jdissloss_si`,
`jexuloss_fe`) stay DEVICE-RESIDENT instead of round-tripping. One `vmove` `target update from` bridge feeds the
host `g_tracer_set_values` calls. 17 kernels unchanged; one enter group + one exit group + 1 bridge.

## Correctness — b2b PASS (bit-faithful)
4×4×75, 48 hr, GPU vs cpu ref: dic 1.30e-16, alk 3.60e-16, no3 0, po4 2.53e-16, o2 1.45e-16 — all PASS,
IDENTICAL to the pre-merge run. The ~100-array union enter/exit is correct (a mis-mapped array would diverge
~1e-4, not 1e-16). `05_b2b.txt`.

## Performance — transfer budget (deterministic; per-call = nsys total ÷ 2)
| metric | pre-merge (5 scopes) | merged | change |
|---|---|---|---|
| HtoD copies | 1365 | 1176 | **−13.8%** |
| HtoD MB | 2996 | 2328 | **−22.3%** (−668 MB/call) |
| DtoH copies | 340 | 344 | +1.2% |
| DtoH MB | 3642 | 3685 | +1.2% (flat) |
| stream syncs | 106 | 103 | −2.8% |
| losses+production GPU wall | ~5.0 s | ~4.8 s | ~−4% (run-variable) |

## The finding (validates the pre-merge review)
The merge reclaims **HtoD** (production stops re-loading losses' outputs: −668 MB/call) and a few syncs — exactly
as predicted. But **DtoH is flat**, because EVERY foodweb output is consumed by the still-CPU downstream
(source/sink, diagnostics), so it must reach host regardless. DtoH (~3.6 GB/call) dominates the wall, so the
wall improvement is modest (~4%).

**Implication:** the merge mechanism is correct and gives a real HtoD win, but its FULL payoff is gated by the
un-ported CPU downstream. The dominant DtoH (and thus the wall) only collapses once source/sink + diagnostics
are also on GPU (outputs produced AND consumed on-device → never copied to host). Steps 2–4 (zoo, bacteria,
growth) will reclaim more HtoD (growth→losses intermediates are a big flow) but remain DtoH-bound until then.

Re-extract: `nsys stats --report cuda_gpu_mem_size_sum m1_budget.nsys-rep` (÷2); speed from `01_budget_speed.txt`.
