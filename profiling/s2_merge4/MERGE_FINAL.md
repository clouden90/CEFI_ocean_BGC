# MERGE step-4 (FINAL): whole COBALT foodweb fused into ONE residency region

Completes the staged merge. growth folded in -> growth->bacteria->zoo->losses->production (17 kernels) is now
ONE resident GPU region: ONE enter (before growth) -> 17 kernels back-to-back -> ONE exit (after production),
with 3 target-update bridges (mld_aclm, f_nh3 [new this step], vmove). Growth's §1.2b enter kept its hard-won
to:/alloc categorization; only the downstream-section arrays were appended. Growth's 13 phyto outputs + expkT
became resident -> downstream stops re-loading them (the biggest single HtoD jump).

## Correctness — b2b PASS (bit-faithful), all 4 steps
Every step (losses+prod -> +zoo -> +bacteria -> +growth) verified bit-faithful: dic 1.30e-16 ... o2 1.45e-16,
identical to every prior run. ~180-array union + new f_nh3 bridge all correct. 05_b2b.txt.

## Performance — transfer budget (deterministic; per-call = nsys total / 2)
| step | region | HtoD MB | syncs |
|---|---|---|---|
| pre | 5 separate scopes | 2996 | 106 |
| 1 | losses+production | 2328 | 103 |
| 2 | +zoo | 1918 | 76 |
| 3 | +bacteria | 1821 | 70 |
| **4 (final)** | **whole foodweb** | **1164** | **61** |
| **cumulative** | | **-61% (-1.83 GB/call)** | **-42%** |

DtoH: 3642 -> 3512 MB/call (~flat). Coupled GPU total ~528 s (flat across all runs 527-538 s).

## The result, stated honestly
The merge reclaimed **61% of HtoD** and **42% of syncs** (deterministic, growth's merge being the biggest jump
since growth feeds all downstream), and collapsed 5 fragile overlapping scopes into ONE clean resident region.
But the **wall is unchanged (~528 s)** — exactly as predicted from step-1: DtoH (~3.5 GB/call) dominates the wall
and is **bounded by the still-CPU downstream** (source/sink, diagnostics), so it cannot shrink until those are
ported. The merge is the necessary groundwork + max HtoD + clean architecture; **the wall win is the downstream
port**, now a trivial extension of this single region (the foodweb outputs would simply stay resident and never
DtoH).

Re-extract: nsys cuda_gpu_mem_size_sum on m4_budget.nsys-rep (/2); speed from 01_budget_speed.txt.
