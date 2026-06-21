# MERGE step-3: bacteria + zoo + losses + production fused into one residency region

Staged merge step 3 of 4. Extends the resident region upstream to include bacteria (3 kernels). Reconciliation:
bact%temp_lim (->losses) and bact%jprod_n (->production) flip to:->alloc: (produced in-region); +jno3denit_wc
accumulator; +bacteria inputs (cobalt%f_no3/f_nh4/f_nh3/f_irr_aclm/f_ldon/f_ldop, phyto(SMALL)%nh4lim). No new
bridge (f_nh3 still external — growth's nh3 island is separate until step-4).

## Correctness — b2b PASS (bit-faithful)
dic 1.30e-16 ... o2 1.45e-16, identical to every prior run. 4-section ~150-array union correct. 05_b2b.txt.

## Performance — transfer budget (deterministic; per-call)
| metric | pre | step-1 | step-2 | step-3 | cumulative |
|---|---|---|---|---|---|
| HtoD MB | 2996 | 2328 | 1918 | **1821** | **-39%** |
| syncs   | 106  | 103  | 76   | **70**   | **-34%** |
| DtoH MB | 3642 | 3685 | 3685 | 3652 | flat |

Region now bacteria->zoo->losses->production (7 kernels, one enter/one exit). HtoD reclaimed; wall stays
DtoH-bound. Step-4 (growth) is the biggest remaining HtoD flow (growth feeds all downstream).
