# §2 bacteria growth — profiling provenance & derivations

Determinism note: copies/bytes/grid/regs/occupancy/SM-SOL deterministic; transfer time, wall, section
timers run-to-run variable (~±10%). 1 step = 2 COBALT calls (÷2 per-call). All numbers machine-verified by
`../verify_s2.py` (BACT block) and figure-integrity by `../verify_all.py`.

| claim | value | source | derivation |
|---|---|---|---|
| bacteria speedup | CPU 1.34 s → GPU 0.46 s = **2.88×** | `06_speed.txt` | `(Cobalt: bacteria growth calcs)` mpp_clock, 128³/12-step |
| coupled total | 614 → 527 s | `06_speed.txt` | `Total runtime` |
| loop1 anammox (F1L4050) | **0.166 ms/call**, grid 9600, REG 48, occ 58.97/62.5%, SM 79.04%, DRAM 2.30%, IPC 1.90 | `03_…txt`, `s2b_full17.csv` | nsys 332,452÷2; ncu --set full |
| loop2 nitrif (F1L4078) | **0.516 ms/call**, grid 9600, REG 64, occ 48.56/50%, SM 68.07%, DRAM 2.73%, IPC 1.71 | `03_…txt`, `s2b_full17.csv` | nsys 1,031,402÷2 |
| loop3 bact-prod (F1L4113) | **1.368 ms/call**, grid 9600, REG 90, occ 31.09/31.25%, SM 49.41%, DRAM 2.33%, IPC 1.16 | `03_…txt`, `s2b_full17.csv` | nsys 2,736,698÷2 |
| b2b (5 tracers) | dic 1.30e-16 … o2 1.45e-16 — all PASS | `05_b2b.txt` | within `max(4×band,1e-13)` |
| kernels in binary | F1L4050, F1L4078, F1L4113 (17 total), REG 48/64/90 | — | `cuobjdump -res-usage` (before measuring) |

**Three loops / one scope:** anammox + nitrification + bacterial production, all collapse(3). The namelist
module var `scheme_nitrif` is `firstprivate` (uniform scalar carried to each thread); host scalar `vmax_bact`
is `firstprivate`; per-cell `bact_uptake_ratio` is `private`. No shared scratch. f_nh3 is the CPU nh3-island
diagnostic (host-resident input). Accumulators `jo2resp_wc`/`jprod_nh4`/`jprod_po4`/`jno3denit_wc` carry
growth's `+=` values -> `to:` AND `from:`; b2b PASS confirms the mapping.

**Within-band (exp + **):** tracer totals identical to prior runs -> bacteria adds zero net deviation.

**All 3 kernels healthy** (SM 49–79%, REG 48–90, no pathology). Section speedup is only 2.88× because
bacteria is the *smallest* foodweb section (CPU 1.34 s) and is transfer-dominated; its strategic value is
completing the growth→bacteria→zoo→losses→production CONTIGUOUS chain that unlocks the residency MERGE.

**Note:** `03_perkernel_and_budget.txt` kern_sum was truncated (head -16) at capture for a 17-kernel run; the
FULL untruncated kern_sum (all 17 per-call times) is appended at the end of that file, and the prof script
template was fixed to `head -24`. The attention report time-weights correctly (losses2D = NEGLIGIBLE).

**Figures** (`figs/`, via `../make_figs.py s2_bacteria`): speed (all 5 foodweb sections ported), per-kernel
SOL (17 kernels, deduped), roofline, ATTENTION.txt.
