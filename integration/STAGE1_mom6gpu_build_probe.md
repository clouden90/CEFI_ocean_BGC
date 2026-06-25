# MOM6-GPU ↔ CEFI integration — Stage-1 build probe: SUCCESS

**Goal (option-1 endgame):** keep tracer arrays device-resident across the MOM6↔COBALT boundary to kill the
~9.5 GB/step DtoH (our M2 nsys budget). COBALT side is done+merged (`feature/gpu` @ de0a4fda4). This probe
answers the integration's hardest unknown: **does Marshall's GPU MOM6 build coupled with CEFI's framework+SIS2+COBALT?**

## Result: YES — coupled MOM6SIS2+COBALT compiled + linked (143 MB exe), 0 errors.

Done in an **isolated tree** (`/scratch5/.../tmp/integ_probe`, sibling `src`+`builds` copy; canonical `cefi/` untouched),
reusing canonical FMS+libyaml (validated identical), building MOM6SIS2 only. Marshall GPU MOM6 = `mom6-gpu` HEAD `fc743d6d6`.

**IMPORTANT caveat:** the sep build scopes offload flags to `generic_COBALT.o` only, so the MOM6 GPU files compiled
as **CPU** (their `!$omp target` ignored, `do concurrent` serial). This proves **interface/API compatibility** (the
real Stage-1 unknown) and yields a valid CPU-MOM6 + GPU-COBALT exe. Actually getting **GPU MOM6** = Stage-1b
(extend offload flags to the MOM6 GPU files; see below).

## Reconciliation recipe (what it took — bounded + well-understood)

ADOPT from Marshall (manifest: `integration/mom6gpu_swap_manifest.txt`, 31 entries):
1. **28 GPU compute files** — dyn-core (MOM, barotropic, continuity_PPM, PressureForce_FV, CoriolisAdv, dynamics_split_RK2,
   interface_heights, porous_barriers, variables, forcing_type), tracer transport (advect, hor_diff), lateral
   (hor_visc, MEKE, interface_filter, lateral_mixing_coeffs, thickness_diffuse), vertical (diabatic_aux,
   diabatic_driver, set_viscosity, vert_friction), diagnostics (diagnostics, sum_output), ALE, state_init, EOS_Wright.
   → **27/28 compiled clean on first try.**
2. **EOS subsystem (3 files: MOM_EOS, MOM_EOS_base_type, MOM_EOS_Wright)** — Marshall ADDS `calculate_density_2d` /
   `calculate_density_derivs_2d` (pure superset +120/+62, no deletions) used by the GPU pressure-force. Other EOS
   impls inherit the base-type default (unchanged → byte-identical).
3. **`src/framework/do_concurrent_compat.h`** — the `DO_LOCALITY()` macro shim for `do concurrent` locality specs
   (found via the `-I src/framework` path).

STUB (1-line, in CEFI's file — keeps CEFI's FMS untouched):
4. **`do_group_pass` gains an accepted-but-ignored `omp_offload` optional arg** (`config_src/infra/FMS2/MOM_domain_infra.F90`).
   All 26 GPU call sites pass `omp_offload=` through this single choke point. Ignoring it = **GPU-compute + CPU-halo**
   intermediate (halo updates run on CPU via CEFI's FMS).

KEEP CEFI's versions (do NOT adopt Marshall's — they carry CEFI regional features or are unused):
- `MOM_PressureForce_Montgomery.F90` — Marshall's calls a 2D EOS overload, but Montgomery is UNUSED
  (`ANALYTIC_FV_PGF=True` → FV is the active scheme). Keep CEFI CPU version.
- `MOM_domains.F90` — Marshall's drops CEFI's `SAVE_UNMASKED_GEOM_FILE` feature. Keep CEFI's (it doesn't carry omp_offload).
- `MOM_open_boundary`, `MOM_tracer_registry/types`, `MOM_diag_mediator`, ODA, ice_shelf, etc. (regional/framework) — kept; caused no errors.

## Identified dependency: full halo-offload needs Marshall's FMS

`do_group_pass` passes `omp_offload` to FMS `mpp_do_group_update`, which **CEFI's FMS lacks** (no `omp_offload` anywhere
in CEFI FMS; Marshall's FMS isn't in the `mom6-gpu` checkout). Current build stubs it (CPU halo). Full GPU halo-offload
(keep halo buffers resident) requires adopting Marshall's FMS `mpp_do_group_update` changes — a foundation-library
dependency affecting the whole coupled model (SIS2/coupler), needs revalidation.

## Next steps
- **Stage-1b**: compile the 28 MOM6 GPU files WITH offload flags (extend the `.mk` target-specific rule beyond
  `generic_COBALT.o`); verify `-stdpar=gpu`/`-mp=gpu` accepts Marshall's constructs → a real GPU-MOM6+GPU-COBALT build.
- **FMS decision**: stub (GPU-compute + CPU-halo, faster) vs adopt Marshall's FMS (full halo-offload).
- **Stage-2/3**: GPU-aware `generic_tracer` bridge (`g_tracer_get_pointer('field')` device-resident) + COBALT residency
  (`is_device_ptr`/`use_device_ptr`) — the actual transfer-elimination payoff.
- **Stage-4**: gaps `MOM_neutral_diffusion` + `MOM_tracer_diabatic` (unported upstream → still round-trip).

Reproduce: isolated tree setup + `integ_probe/build_probe.sbatch` (reuses canonical FMS, MOM6SIS2-only, `make -k`).
