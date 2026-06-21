# §2 other losses — profiling provenance & derivations

Determinism note: copies/bytes/syncs/grid/regs/occupancy/SM-SOL deterministic (reproduce exactly);
transfer time, wall, section timers run-to-run variable (~±10%). 1 step = 2 COBALT calls (÷2 per-call).
All numbers machine-verified by `../verify_s2.py` (LOSSES block) against this archive.

| claim | value | source | derivation |
|---|---|---|---|
| other-losses speedup | CPU 11.99 s → GPU 2.81 s = **4.27×** | `06_speed.txt` | `(Cobalt: other losses)` mpp_clock, 128³/12-step |
| coupled total | 620 → 527 s | `06_speed.txt` | `Total runtime` |
| loop1 kernel (F1L4593, 3D) | **7.11 ms/call**, grid 9600, REG 56, occ 53.5/56.25%, **SM 75.36%**, DRAM 3.47%, IPC 1.72 | `03_…txt`, `s2l_full14.csv` | nsys 14,219,580÷2; ncu --set full |
| loop2 kernel (F1L4704, 2D surface) | **0.021 ms/call**, grid 128, REG 56, occ 6.23%, SM 8.13%, DRAM 0.23%, IPC 0.22 | `03_…txt`, `s2l_full14.csv` | nsys 42,304÷2; grid-starved but NEGLIGIBLE |
| b2b (5 tracers) | dic 1.30e-16, alk 3.60e-16, no3 0, po4 2.53e-16, o2 1.45e-16 — all PASS | `05_b2b.txt` | within `max(4×band,1e-13)` |
| kernels in binary | F1L4593, F1L4704 (14 total), REG 56 each | — | `cuobjdump -res-usage` (before measuring) |

**Effectively bit-faithful:** the `**2`/`**2.0` are integer squares (compiled to x*x, not pow), so losses-on-GPU
== losses-on-CPU bit-for-bit; the b2b totals are IDENTICAL to the prior (zoo) run — losses adds zero deviation.

**Accumulators verified (the alloc-vs-to: rule):** `jdissloss_si` (carries growth §1.3 value, L4630 +=) and
`jexuloss_fe` (carries growth L3971 value, L4670/4674 +=) are mapped `to:` AND `from:`. b2b PASS confirms the
mapping is correct (a mis-map diverges ~1e-4, not 1e-16).

**Two-loop / one-scope structure:** loop1 (3D collapse(3)) + loop2 (2D surface collapse(2)) share one residency
region; `vmove` stays resident loop1→loop2; exit data runs BEFORE the host `g_tracer_set_values` calls that read
`vmove`. No shared scratch (no firstprivate).

**Efficiency note:** loop1 is the healthiest foodweb kernel (75% SM, no pathology). But the section is only 4.27×
(vs zoo 8.37×) because the kernel is tiny (7 ms) while many phyto loss-field arrays are mapped → ~94% of the
2.81 s is transfer. This is the strongest case for the cross-section MERGE: losses' inputs come from growth and
outputs feed production, so a contiguous resident chain reclaims nearly all of it.

**Figures** (`figs/`, via `../make_figs.py s2_losses`): speed (all 4 foodweb sections now ported), per-kernel SOL,
roofline, ATTENTION.txt. Attention now time-weights: loss2D flagged NEGLIGIBLE (0.021 ms), real TUNE candidates
ranked Geider 54 / E,zoo 28 / A 7.7 ms.
