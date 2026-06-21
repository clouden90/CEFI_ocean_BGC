# §1.2b growth-block — profiling provenance & re-verification

Every performance number in the PR / `GPU_PORTING.md` traces to an archived artifact here, with the
command to re-derive it. Files `01–04` are **regenerated from the surviving `.nsys-rep`/`.ncu-rep` binary
profiles** (the authoritative source); `05–08` are the raw job logs. `scripts/` holds the profiling sbatch
scripts so the `.rep` files themselves are reproducible (re-run on the merged GPU build,
`build/nvhpc-x86-sep-nompi/.../MOM6SIS2`, in `exps/OM4.scale128.COBALT.nompi` with `input.nml_1step`).

**Determinism note:** *copies, bytes, syncs, grid, registers, occupancy, SM-SOL* are **deterministic** (set by
the code) and reproduce exactly. *Transfer time and wall-clock* are **run-to-run variable (~±10%)** on the
shared node — reported values are from the archived `.rep` of record; the deterministic metrics are the
robust comparison.

| PR claim | value | source file | re-extract command |
|---|---|---|---|
| §3a kernel compute /call | 103 ms | `01_budget_10scope.txt` | `nsys stats --report cuda_gpu_kern_sum budget.nsys-rep` → Σ/2 |
| §3a 10-scope DtoH | 141 copies / 1.50 GB | `01_…txt` | `cuda_gpu_mem_size_sum/time_sum` (282 ops, 2995 MB) ÷2 |
| §3a 10-scope HtoD | 696 / 1.89 GB | `01_…txt` | same (1392 ops, 3773 MB) ÷2 |
| §3a 10-scope syncs / transfer-time | 95 / 373 ms | `01_…txt` | `cuda_api_sum` cuStreamSynchronize 190÷2; (DtoH+HtoD time)/2 |
| §3a merged DtoH / HtoD / syncs | 137·1.45GB / 402·0.85GB / 28 | `02_budget_merged.txt` | same reports on `mbud.nsys-rep` (274/804 ops, 2909/1702 MB, 56 sync) ÷2 |
| §3a merged transfer-time | 331 ms (run-variable) | `02_…txt` | (436.1M DtoH + 226.0M HtoD)/2 ns |
| §3b per-kernel (grid/regs/occ/SM/DRAM/IPC/warp) all 10 | (table) | `03_perkernel_ncu.txt` | `ncu --import full10.ncu-rep --page details` |
| §3c roofline (AI, GFLOP/s) | §1.1 2.14/175, A 2.51/42, B 0.20/18 | `04_roofline_flops.txt` | FLOPs=dadd+dmul+2·dfma; AI=FLOPs/dram_bytes; GFLOP/s=FLOPs/time |
| §3b/§3e kernel times (nsys) | Geider 54, E 28, A 7.7, … | `01_…txt` kern_sum | per-kernel Avg(ns) (= per-call) |
| §2 b2b (5 tracers, within-band PASS) | dic 6.5e-16 … o2 2.9e-16 | `05_b2b.txt` | the b2b harness tracer-totals diff vs `gpu_b2b_ref/` |
| §3e speed (growth 4.33×, CPU 72→GPU 16.6) | — | `06_speed.txt` | `(Cobalt: phytoplankton growth)` mpp_clock, CPU vs GPU |
| §4 Tier-2 -O2 A/B | restr 76.6 / prist 74.9 s | `07_tier2_O2_objswap.txt` | object-swap growth timer, `out.objO2_{cur,prist}` |
| §3d construct A/B (dc vs collapse3) | Geider grid 75→9600, 6.25→18.74% occ, SM 6.33→31.77%, **448→90 ms (ncu) ≈5×** | `08_construct_AB_dc_vs_collapse3.txt` | `ncu --set full` on `MOM6SIS2.dc` vs `.cc3` (§1.1 regression is in `GPU_PORTING.md`, not this archive) |
| §6 per-section costs | carbon ~40, production ~18, zoo ~16, losses ~13, source/sink ~17 s | `09_section_costs.txt` | mpp_clock COBALT sections from out.speed_gpu (run-variable) |

**Full re-verification (2026-06-21):** EVERY number re-derived from the archived files (01–09). **4 issues found
& corrected** in the PR (all *run-variable* or *un-archived-source* metrics — never the deterministic/headline numbers):
(a) coupled CPU total 619→**612**; (b) merged transfer-time 308→**331 ms** (−17%→−11%, since-overwritten run);
(c) §3d now cites the **archived ncu A/B** (448→90 ms, grid 75→9600) instead of un-archived nsys (272→54), §1.1
referred to `GPU_PORTING.md`; (d) §6 production 20→**18 s**, other losses 15→**13 s** (matched to archived `09`).
All **headline + deterministic** numbers verified **EXACT**: 4.33×, the full §3b 80-cell per-kernel table, §3c
roofline, §2 b2b within-band, all copies/bytes/syncs. Run-variable metrics (transfer time, wall, section
timers) are reconciled to the archived run of record.
