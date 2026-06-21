# §2 zooplankton — profiling provenance & derivations

Determinism note: copies/bytes/syncs/grid/regs/occupancy/SM-SOL are deterministic and reproduce exactly;
transfer time, wall-clock, section timers are run-to-run variable (~±10%). 1 step = 2 COBALT calls (÷2 per-call).

| claim | value | source file | derivation |
|---|---|---|---|
| zooplankton speedup | CPU 14.58 s → GPU 1.74 s = **8.37×** | `06_speed.txt` | `(Cobalt: zooplankton calculation)` mpp_clock, 128³/12-step |
| coupled total | 613 → 542 s | `06_speed.txt` | `Total runtime` rows |
| zoo kernel time | **28.6 ms/call** | `03_perkernel_and_budget.txt` | nsys `cuda_gpu_kern_sum` F1L4278 = 57,223,616 ns ÷ 2 |
| zoo kernel (ncu --set full) | grid 9600, **REG 136**, occ 18.63/18.75%, SM-SOL 29.23%, DRAM 1.59%, IPC 0.70, warp 17.03, L2 89.34% | `03_…txt`, `s2z_full12.csv` | ncu, kernel F1L4278 |
| roofline | from `s2z_roof12` raw counters | `03_…txt` ROOFLINE block | FLOPs = dadd+dmul+2·dfma; ÷ dram; ÷ time |
| b2b (5 tracers) | dic 1.30e-16, alk 3.60e-16, no3 0, po4 2.53e-16, o2 1.45e-16 — all PASS | `05_b2b.txt` | tracer-total diff vs cpu ref, within `max(4×band,1e-13)` |
| kernel in binary | F1L4278 (12th kernel), REG 136 STACK 1216 | — | `cuobjdump -res-usage` (verified before measuring) |

**Within-band, not bit-identical:** zoo has `exp` + `**` (pow), so GPU MUFU transcendentals differ from CPU libm
at the last ULP. Tracer totals *shifted* vs the production-only run (dic 6.49e-16 → 1.30e-16) but stayed within
band — the expected within-band signature, and proof the firstprivate scratch design is correct (a wrong
private/firstprivate split would diverge ~1e-4 / NaN, not 1e-16).

**The firstprivate decision (the crux of this port):** ipa_matrix, hp_ipa_vec, prey_p2n_vec, prey_fe2n_vec,
prey_si2n_vec, ingest_matrix, hp_ingest_vec are per-thread scratch that RELY on the host pre-loop init
(e.g. `ingest_matrix(3,4)` is read at L4438 but never set for m=3 → needs the pre-loop `=0`) → `firstprivate`
(each thread gets the initialized copy). prey_vec/pa_matrix/hp_pa_vec/tot_prey/tot_prey_hp/food1/food2/
sw_fac_denom are fully recomputed per cell → `private`. REG 136 (firstprivate scratch spills to STACK 1216)
caps occupancy at 18.6% → tuning candidate (flagged in figs/ATTENTION.txt alongside Geider/A/E).

**Figures** (`figs/`, via `../make_figs.py s2_zoo`): fig_speed_beforeafter, fig_perkernel_sol, fig_roofline,
ATTENTION.txt. Production shows 7.37× in this run (run-variable; the dedicated run measured 7.84×).
