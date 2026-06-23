#!/usr/bin/env python3
"""Generate §3 (ballast + source/sink + M2) consolidation figures from measured data.
Data sources: profiling/S3_CONSOLIDATION.md (per-loop timing, nsys transfer) + consol ncu run.
All numbers are measured; honest annotations where a comparison is confounded."""
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

C_CPU, C_AP, C_M2 = '#9aa0a6', '#f4a259', '#2a9d8f'   # cpu / all-pointer / M2
plt.rcParams.update({'font.size': 10, 'axes.grid': True, 'grid.alpha': 0.25, 'axes.axisbelow': True})

fig, ax = plt.subplots(1, 3, figsize=(16, 4.8))
fig.suptitle('COBALT §3 GPU port — ballast + source/sink + M2 region-merge (GH200, 128³)', fontweight='bold')

# ---- Panel A: achieved GPU speedup per section (CPU vs GPU-M2) ----
secs   = ['ballast*', 'src/sink\nloop2', 'src/sink\nloop3', 'src/sink\nloop5', 'src/sink\nloop6']
cpu    = [3.7, 4.7, 1.8, 1.5, 4.3]
m2     = [0.35, 0.63, 0.55, 0.34, 1.60]
x = np.arange(len(secs)); w = 0.38
ax[0].bar(x-w/2, cpu, w, label='CPU (-O0)', color=C_CPU)
ax[0].bar(x+w/2, m2,  w, label='GPU M2',    color=C_M2)
for xi, (c, m) in enumerate(zip(cpu, m2)):
    ax[0].annotate(f'{c/m:.1f}×', (xi, max(c, m)), textcoords='offset points', xytext=(0, 3),
                   ha='center', fontsize=8.5, color='#264653')
ax[0].set_xticks(x); ax[0].set_xticklabels(secs); ax[0].set_ylabel('time per section (s, 12-step)')
ax[0].set_title('(A) Achieved GPU speedup per section'); ax[0].legend(frameon=False)

# ---- Panel B: M2 re-HtoD elimination (all-pointer -> M2), source/sink loops ----
ss   = ['loop2', 'loop3', 'loop5', 'loop6']
ap   = [0.90, 0.81, 0.53, 1.47]
m2ss = [0.63, 0.55, 0.34, 1.60]
xb = np.arange(len(ss))
ax[1].bar(xb-w/2, ap,   w, label='GPU all-pointer', color=C_AP)
ax[1].bar(xb+w/2, m2ss, w, label='GPU M2 (resident)', color=C_M2)
ax[1].set_xticks(xb); ax[1].set_xticklabels(ss); ax[1].set_ylabel('time per loop (s, 12-step)')
ax[1].set_title('(B) M2 eliminates source/sink re-HtoD'); ax[1].legend(frameon=False)
ax[1].annotate('loops 2/3/5: −30%/−32%/−36%\n(foodweb intermediates stay resident)\nloop6 ~flat',
               (0.02, 0.97), xycoords='axes fraction', va='top', fontsize=8, color='#264653',
               bbox=dict(boxstyle='round', fc='white', ec='#cccccc', alpha=0.9))

# ---- Panel C: source/sink kernel occupancy vs register pressure (ncu --set basic) ----
ker  = ['F1L3556', 'F1L3686', 'F1L3780', 'F1L3825', 'F1L3907']
regs = [72, 255, 74, 130, 90]
occ  = [43.6, 6.25, 37.0, 18.7, 31.1]
xc = np.arange(len(ker))
b = ax[2].bar(xc, occ, 0.55, color=C_M2, label='achieved occupancy %')
ax[2].set_xticks(xc); ax[2].set_xticklabels(ker, rotation=20, fontsize=8.5)
ax[2].set_ylabel('achieved occupancy (%)'); ax[2].set_ylim(0, 50)
ax[2].set_title('(C) Occupancy limited by register pressure')
ax2 = ax[2].twinx(); ax2.plot(xc, regs, 'o-', color='#e76f51', label='registers/thread')
ax2.set_ylabel('registers / thread', color='#e76f51'); ax2.set_ylim(0, 270)
ax2.axhline(255, ls=':', color='#e76f51', alpha=0.6)
ax2.tick_params(axis='y', colors='#e76f51')
ax[2].annotate('F1L3686 growth kernel:\n255 reg → spilled → 6.25% occ\n(tuning candidate)',
               (1, 8), textcoords='offset points', xytext=(6, 40), fontsize=8, color='#9c2a2a',
               arrowprops=dict(arrowstyle='->', color='#9c2a2a'))
h1, l1 = ax[2].get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax[2].legend(h1+h2, l1+l2, frameon=False, loc='upper right', fontsize=8)

fig.text(0.5, 0.004, '* ballast: CPU→M2 is a compute-only comparison (under M2 the exit-DtoH is accounted once at the '
         'merged-region exit, not per-loop). Correctness: Tier-1 (-O0) bit-identical + GPU 17-tracer b2b bit-faithful '
         '(worst 2.87e-14).  nsys M2 transfer budget: HtoD 3.5 GB / DtoH 9.5 GB, 27 kernels (128³, 1-step).',
         ha='center', fontsize=7.5, color='#555555')
fig.tight_layout(rect=[0, 0.03, 1, 0.96])
out = 's3_consolidation_figures.png'
fig.savefig(out, dpi=150, bbox_inches='tight')
print('wrote', out)
