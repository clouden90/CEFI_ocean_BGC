#!/usr/bin/env python3
"""
make_figs.py — reusable profiling-figure generator for the COBALT GPU port.

Companion to verify.py. Renders the per-PR profiling figures from the SAME committed,
re-derivable artifacts that verify.py checks (ncu --csv dumps + the speed log) — never
from GUI screenshots. So every figure is reproducible (`python3 make_figs.py <archive_dir>`),
diff-stable, and survives the /scratch5 purge (PNG + this script + source CSV all in git).

Inputs in <archive_dir> (default: s2_production):
  s2_full11.csv   ncu --set full --csv --page details  (per-kernel SOL/occ/regs/DRAM/...)
  s2_roof11.csv   ncu roofline metrics --csv --page raw (dadd/dmul/dfma/dram_bytes/time)
  06_speed.txt    mpp_clock CPU vs GPU section timers

Outputs (PNG, headless Agg) into <archive_dir>/figs/:
  fig_speed_beforeafter.png   CPU vs GPU section times (the before/after)
  fig_perkernel_sol.png       SM-SOL% + DRAM% for all kernels, production highlighted
  fig_roofline.png            all kernels on the H100 FP64 + HBM roofline
"""
import csv, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---- per-PR config: F1L<line> -> short label, in launch order (line #s shift as ports add code) ----
SECTION_MAP = {
    "F1L3510": "§1.1", "F1L3640": "A", "F1L3734": "B", "F1L3776": "Geider",
    "F1L3858": "E", "F1L3873": "F", "F1L3893": "§1.3N", "F1L3931": "§1.3P",
    "F1L3956": "§1.3Fe", "F1L3978": "§1.3Si", "F1L4050": "bact-amx", "F1L4078": "bact-nitrif", "F1L4113": "bact-prod",
    "F1L4278": "zoo", "F1L4303": "zoo", "F1L4593": "losses", "F1L4618": "losses",
    "F1L4704": "losses2D", "F1L4729": "losses2D",
    # production's directive line shifts as ports add code above it; keep all aliases so every
    # archive's CSV (profiled at its line of the day) still resolves: §2 prod=F1L4707, post-zoo=F1L4748
    "F1L4707": "production", "F1L4748": "production", "F1L4780": "production", "F1L4805": "production",
}
HIGHLIGHT = "bact-prod"                # the kernel this PR adds (cosmetic: which SOL bar is red)
# A section is "ported" iff its GPU time is well below CPU. INFERRED FROM THE DATA (not a global list) so
# each archive's figure reflects ITS OWN era — e.g. s2_production's fig correctly shows zoo as un-ported,
# while s2_zoo's shows it ported. Ported sections run 4-8x (ratio ~0.1-0.25); un-ported are flat/slower (~1+).
PORTED_RATIO = 0.7
def is_ported(cpu, gpu): return bool(cpu) and gpu/cpu < PORTED_RATIO
NEGLIGIBLE_MS = 0.5   # a low-SM kernel below this nsys ms/call is grid-starved-but-cheap, NOT a tuning target
# Attention thresholds (the review discipline: every port flags what needs work)
NOISE_PCT   = 5.0    # un-ported section slower than CPU by > this % on the GPU build -> flag
LOW_SOL_PCT = 35.0   # kernel SM-SOL below this -> under-utilized, flag for tuning
# H100 NVL roofs (FP64 vector peak, HBM3 BW) — for the roofline ceilings
H100_FP64_GFLOPS = 34_000.0
H100_HBM_GBs     = 3_900.0

def _f(s):
    try: return float(str(s).replace(",", "").strip())
    except: return None

def kern_tag(name):
    m = re.search(r"(F1L\d+)", name or "")
    return SECTION_MAP.get(m.group(1)) if m else None

def parse_details(path):
    """ncu details CSV (long): rows of (Kernel Name, Metric Name, Metric Value) -> {tag:{metric:val}}."""
    out = {}
    with open(path, newline="") as fh:
        r = csv.DictReader(fh)
        for row in r:
            tag = kern_tag(row.get("Kernel Name", ""))
            if not tag: continue
            mn, mv = row.get("Metric Name", ""), _f(row.get("Metric Value", ""))
            if mn and mv is not None:
                out.setdefault(tag, {})[mn] = mv
    return out

_BYTE_U = {"byte": 1.0, "Kbyte": 1e3, "Mbyte": 1e6, "Gbyte": 1e9, "Tbyte": 1e12}
_SEC_U  = {"nsecond": 1e-9, "usecond": 1e-6, "msecond": 1e-3, "ms": 1e-3, "second": 1.0, "s": 1.0}

def parse_roof(path):
    """Parse ncu --page raw TEXT (has explicit unit column) -> {tag:(AI [FLOP/B], GFLOP/s)}.
    Robust to ncu's per-kernel unit auto-scaling (Mbyte vs Gbyte) which the wide CSV loses."""
    cur, acc = None, {}
    for ln in open(path):
        if "F1L" in ln and "nvkernel" in ln:
            cur = kern_tag(ln); acc.setdefault(cur, {}) if cur else None
            continue
        if not cur: continue
        f = ln.split()
        if len(f) < 3: continue
        name, unit, val = f[0], f[-2], _f(f[-1])
        if val is None: continue
        if name == "dram__bytes.sum":               acc[cur]["dram"] = val * _BYTE_U.get(unit, 1.0)
        elif name == "gpu__time_duration.sum":       acc[cur]["t"]    = val * _SEC_U.get(unit, 1.0)
        elif name.endswith("op_dadd_pred_on.sum"):   acc[cur]["add"]  = val
        elif name.endswith("op_dmul_pred_on.sum"):   acc[cur]["mul"]  = val
        elif name.endswith("op_dfma_pred_on.sum"):   acc[cur]["fma"]  = val
    out = {}
    for tag, d in acc.items():
        if {"dram", "t", "add", "mul", "fma"} <= d.keys() and d["dram"] > 0 and d["t"] > 0:
            flops = d["add"] + d["mul"] + 2*d["fma"]
            out[tag] = (flops/d["dram"], flops/d["t"]/1e9)
    return out

def parse_speed(path):
    """06_speed.txt -> {section: (cpu_s, gpu_s)} from the mpp_clock rows."""
    txt = open(path).read()
    secs = ["carbon", "phytoplankton growth", "bacteria growth", "zooplankton", "other losses", "production loop"]
    out = {}
    for s in secs:
        # section label, then any text (" calcs)", " ca", ...), then the count int, then the first time
        cpu = re.search(rf"\[cpu\][^\n]*?{re.escape(s)}[^\n]*?\s+\d+\s+([\d.]+)", txt)
        gpu = re.search(rf"\[gpu\][^\n]*?{re.escape(s)}[^\n]*?\s+\d+\s+([\d.]+)", txt)
        if cpu and gpu: out[s] = (float(cpu.group(1)), float(gpu.group(1)))
    return out

def fig_speed(speed, outdir):
    labels = list(speed.keys()); cpu = [speed[k][0] for k in labels]; gpu = [speed[k][1] for k in labels]
    x = range(len(labels)); w = 0.38
    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    ax.bar([i-w/2 for i in x], cpu, w, label="CPU", color="#9aa7b4")
    # ported sections = solid green (a real GPU win); un-ported = hatched grey (still CPU, context only)
    for i, k in enumerate(labels):
        ported = is_ported(cpu[i], gpu[i])
        ax.bar(i+w/2, gpu[i], w, color="#2e7d32" if ported else "#cfd6dd",
               hatch=None if ported else "//", edgecolor="#7a8590" if not ported else None)
        r = gpu[i]/cpu[i] if cpu[i] else 1
        if ported:
            ax.annotate(f"{cpu[i]/gpu[i]:.1f}×", (i+w/2, gpu[i]), textcoords="offset points",
                        xytext=(0, 4), ha="center", fontsize=10, fontweight="bold", color="#1b5e20")
        elif r > 1 + NOISE_PCT/100.0:   # un-ported AND slower than noise -> flag in red
            ax.annotate(f"+{(r-1)*100:.0f}%", (i+w/2, gpu[i]), textcoords="offset points",
                        xytext=(0, 4), ha="center", fontsize=9, fontweight="bold", color="#c62828")
    from matplotlib.patches import Patch
    leg = [Patch(color="#9aa7b4", label="CPU"), Patch(color="#2e7d32", label="GPU — ported (win)"),
           Patch(facecolor="#cfd6dd", hatch="//", edgecolor="#7a8590", label="GPU — un-ported (still CPU)")]
    ax.legend(handles=leg, fontsize=8)
    ax.set_xticks(list(x)); ax.set_xticklabels([k.replace(" ", "\n") for k in labels], fontsize=9)
    ax.set_ylabel("time over 12 steps (s)")
    ax.set_title("COBALT section time: CPU vs GPU  (128³, 12 steps, H100)\ngreen = ported win · hatched = un-ported (runs on CPU in the GPU build)")
    fig.tight_layout()
    p = os.path.join(outdir, "fig_speed_beforeafter.png"); fig.savefig(p, dpi=130); plt.close(fig); return p

def fig_sol(det, outdir):
    order = []  # dedup: SECTION_MAP has multiple F1L aliases -> same tag; keep launch order, no repeat bars
    for t in SECTION_MAP.values():
        if t in det and t not in order: order.append(t)
    sm   = [det[t].get("Compute (SM) Throughput", 0) for t in order]
    dram = [det[t].get("DRAM Throughput", 0) for t in order]
    x = range(len(order)); w = 0.38
    fig, ax = plt.subplots(figsize=(10, 4.5))
    cols = ["#c62828" if t == HIGHLIGHT else "#1565c0" for t in order]
    ax.bar([i-w/2 for i in x], sm, w, label="SM SOL %", color=cols)
    ax.bar([i+w/2 for i in x], dram, w, label="DRAM %", color="#ffb300")
    ax.set_xticks(list(x)); ax.set_xticklabels(order, rotation=35, ha="right", fontsize=9)
    ax.set_ylabel("% of speed-of-light"); ax.set_ylim(0, 100)
    ax.set_title("Per-kernel utilization (ncu --set full); production in red")
    ax.legend(); fig.tight_layout()
    p = os.path.join(outdir, "fig_perkernel_sol.png"); fig.savefig(p, dpi=130); plt.close(fig); return p

def fig_roofline(roof, det, outdir):
    fig, ax = plt.subplots(figsize=(7.5, 5.5))
    ridge = H100_FP64_GFLOPS / H100_HBM_GBs
    ai = [10**(i/20.0) for i in range(-60, 41)]            # 1e-3 .. 1e2 FLOP/B
    bw = [min(H100_FP64_GFLOPS, a*H100_HBM_GBs) for a in ai]
    ax.plot(ai, bw, "k-", lw=1.4)
    ax.axhline(H100_FP64_GFLOPS, ls="--", c="grey", lw=0.8)
    ax.text(ai[-1], H100_FP64_GFLOPS*1.05, "FP64 peak ~34 TFLOP/s", ha="right", fontsize=8, color="grey")
    ax.text(ridge*0.5, ridge*H100_HBM_GBs*0.4, "HBM3\n~3.9 TB/s", rotation=34, fontsize=8, color="grey")
    for t, (a, g) in roof.items():
        c = "#c62828" if t == HIGHLIGHT else "#1565c0"
        ax.loglog(a, g, "o", color=c, ms=8 if t == HIGHLIGHT else 6)
        ax.annotate(t, (a, g), textcoords="offset points", xytext=(6, 4), fontsize=8, color=c)
    ax.set_xlabel("arithmetic intensity (FLOP/byte)"); ax.set_ylabel("achieved GFLOP/s")
    ax.set_title("Roofline (H100, FP64) — COBALT kernels are latency-bound\n(far below both the FP64 and HBM roofs)")
    ax.grid(True, which="both", ls=":", alpha=0.4); fig.tight_layout()
    p = os.path.join(outdir, "fig_roofline.png"); fig.savefig(p, dpi=130); plt.close(fig); return p

def parse_nsys_ktime(path):
    """nsys kern_sum block in the perkernel/budget log -> {tag: ms/call} (total ns ÷ 2 calls ÷ 1e6)."""
    out = {}
    for ln in open(path):
        m = re.search(r"^\s*[\d.]+\s+(\d+)\s+2\s+[\d.]+.*F1L(\d+)", ln)
        if m:
            tag = SECTION_MAP.get("F1L"+m.group(2))
            if tag: out[tag] = int(m.group(1))/2/1e6
    return out

def attention_report(speed, det, outdir, ktime=None):
    """The review discipline: after every port, auto-flag what needs attention so we don't have to
    eyeball the figures. Writes figs/ATTENTION.txt and prints. Two checks:
      (1) un-ported sections that got SLOWER on the GPU build by > noise (GPU-build CPU-section drift);
      (2) GPU kernels with SM-SOL below LOW_SOL_PCT (under-utilized -> tuning candidates)."""
    lines = ["# Attention report — what needs a closer look after this port", ""]
    lines.append("## Un-ported sections slower on the GPU build (still CPU; watch as we port more)")
    any1 = False
    for k, (c, g) in speed.items():
        if is_ported(c, g):
            lines.append(f"  - {k:24s} {c/g:5.2f}× FASTER  (ported ✓)"); continue
        pct = (g/c - 1)*100 if c else 0
        if pct > NOISE_PCT:
            lines.append(f"  - {k:24s} +{pct:4.0f}% SLOWER on GPU build  ⚠ (un-ported, above {NOISE_PCT:.0f}% noise)"); any1 = True
        else:
            lines.append(f"  - {k:24s} {pct:+5.0f}% (within noise)")
    if not any1: lines.append("  (none above noise)")
    lines += ["", "## Under-utilized GPU kernels (SM-SOL < %.0f%% -> tuning candidates)" % LOW_SOL_PCT]
    any2 = False; seen = set()
    for t in SECTION_MAP.values():
        if t in det and t not in seen:
            seen.add(t)
            sol = det[t].get("Compute (SM) Throughput", 0)
            if sol < LOW_SOL_PCT:
                ms = (ktime or {}).get(t)
                if ms is not None and ms < NEGLIGIBLE_MS:
                    lines.append(f"  - {t:10s} SM-SOL {sol:5.1f}%  ({ms:.3f} ms/call — grid-starved but NEGLIGIBLE, skip)")
                else:
                    tm = f"{ms:.1f} ms/call" if ms is not None else "time n/a"
                    lines.append(f"  - {t:10s} SM-SOL {sol:5.1f}%  ⚠ TUNE ({tm})"); any2 = True
    if not any2: lines.append("  (no significant under-utilized kernel)")
    txt = "\n".join(lines) + "\n"
    open(os.path.join(outdir, "ATTENTION.txt"), "w").write(txt)
    print("\n" + txt)

def _find(base, *patterns):
    import glob
    for p in patterns:
        hits = sorted(glob.glob(os.path.join(base, p)))
        if hits: return hits[0]
    return os.path.join(base, patterns[0])   # nonexistent -> parser handles/raises

def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "s2_production")
    outdir = os.path.join(base, "figs"); os.makedirs(outdir, exist_ok=True)
    # glob the canonical artifacts so this works for any section dir (s2_production, s2_zoo, ...)
    det  = parse_details(_find(base, "*full*.csv"))
    roof = parse_roof(_find(base, "*perkernel*budget*.txt", "03_*.txt"))   # text page: has unit column
    speed = parse_speed(_find(base, "*speed*.txt", "06_*.txt"))
    print(f"  parsed: {len(det)} kernels (details), {len(roof)} (roofline), {len(speed)} sections (speed)")
    made = []
    if speed: made.append(fig_speed(speed, outdir))
    if det:   made.append(fig_sol(det, outdir))
    if roof:  made.append(fig_roofline(roof, det, outdir))
    for m in made: print(f"  wrote {m}")
    ktime = parse_nsys_ktime(_find(base, "*perkernel*budget*.txt", "03_*.txt"))
    if speed or det: attention_report(speed, det, outdir, ktime)
    print(f"  DONE — {len(made)} figures in {outdir}")

if __name__ == "__main__":
    main()
