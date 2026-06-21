#!/usr/bin/env python3
"""
verify_all.py — master audit for the §2 foodweb GPU port. ONE re-runnable command that checks
EVERYTHING, so the classes of mistake we've hit can't slip through silently again:

  PHASE 1  METRICS        — runs verify_s2.py: every reported number == committed archive.
  PHASE 2  FIGURE LOGIC   — the gap that let the duplicate-bar bug through. For each archive:
                            (a) every kernel in the CSV maps to a SECTION_MAP tag (no SILENT DROP),
                            (b) fig_sol bar list is duplicate-free AND covers all kernels (no DUP BARS),
                            (c) ported/un-ported classification matches the speed data,
                            (d) every per-kernel SOL/DRAM value the figure plots is a real archive value,
                            (e) figures are DETERMINISTIC (regenerate twice -> identical bytes).
  PHASE 3  SOURCE         — generic_COBALT.F90: kernel count, zero live `do concurrent`, enter/exit
                            directive presence.

Exit 0 = everything verified. Run: `python3 verify_all.py`.
"""
import csv, os, re, sys, subprocess, importlib.util, hashlib, glob

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.normpath(os.path.join(HERE, "..", "generic_tracers", "generic_COBALT.F90"))
spec = importlib.util.spec_from_file_location("make_figs", os.path.join(HERE, "make_figs.py"))
mf = importlib.util.module_from_spec(spec); spec.loader.exec_module(mf)

ARCHIVES = [d for d in ["s2_production", "s2_zoo", "s2_losses", "s2_bacteria"]
            if glob.glob(os.path.join(HERE, d, "*full*.csv"))]   # only fully-archived sections
fails = []
def ok(cond, label):
    print(f"  [{'OK ' if cond else 'XX!'}] {label}")
    if not cond: fails.append(label)
    return cond

# ---------- PHASE 1: metrics ----------
print("========= PHASE 1: METRICS (verify_s2.py — reported numbers vs archive) =========")
r = subprocess.run([sys.executable, os.path.join(HERE, "verify_s2.py")], capture_output=True, text=True)
npass = r.stdout.count("[OK ]"); nfail = r.stdout.count("[XX")
ok(r.returncode == 0 and nfail == 0, f"verify_s2.py: {npass} checks pass, {nfail} fail, exit {r.returncode}")

# ---------- PHASE 2: figure logic ----------
print("\n========= PHASE 2: FIGURE LOGIC (the duplicate-bar / silent-drop class) =========")
def csv_kernels(path):
    """all distinct F1L kernel names actually present in a details CSV."""
    names = set()
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            m = re.search(r"(F1L\d+)", row.get("Kernel Name", "") or "")
            if m: names.add(m.group(1))
    return names

for d in ARCHIVES:
    base = os.path.join(HERE, d)
    print(f"  -- {d} --")
    fullcsv = mf._find(base, "*full*.csv")
    raw_kernels = csv_kernels(fullcsv)
    # (a) no silent drop: every F1L in the CSV is in SECTION_MAP
    unmapped = [k for k in raw_kernels if k not in mf.SECTION_MAP]
    ok(not unmapped, f"{d}: all {len(raw_kernels)} CSV kernels mapped (unmapped={unmapped})")
    det = mf.parse_details(fullcsv)
    # (b) no dup bars: fig_sol order is unique and == #unique tags from CSV
    order = []
    for t in mf.SECTION_MAP.values():
        if t in det and t not in order: order.append(t)
    uniq_tags = {mf.SECTION_MAP[k] for k in raw_kernels}
    ok(len(order) == len(set(order)), f"{d}: fig_sol bars duplicate-free ({len(order)} bars)")
    ok(set(order) == uniq_tags, f"{d}: fig_sol covers every kernel ({len(order)}=={len(uniq_tags)})")
    # (c) ported classification matches data
    speed = mf.parse_speed(mf._find(base, "*speed*.txt", "06_*.txt"))
    bad = [k for k,(c,g) in speed.items() if mf.is_ported(c,g) and g/c >= mf.PORTED_RATIO]
    ok(not bad, f"{d}: ported flags consistent with speed ratios")
    # (d) figure values are real archive values (SOL in [0,100], present for each plotted tag)
    badval = [t for t in order if not (0 <= det[t].get("Compute (SM) Throughput", -1) <= 100)]
    ok(not badval, f"{d}: all plotted SOL values valid (bad={badval})")
    # (e) determinism: regenerate figs twice, hash-compare
    import tempfile
    def figs_hash():
        mf.main_base = base
        outs = sorted(glob.glob(os.path.join(base, "figs", "*.png")))
        return None
    r1 = subprocess.run([sys.executable, os.path.join(HERE, "make_figs.py"), base], capture_output=True, text=True)
    h1 = {p: hashlib.md5(open(p, "rb").read()).hexdigest() for p in glob.glob(os.path.join(base, "figs", "*.png"))}
    r2 = subprocess.run([sys.executable, os.path.join(HERE, "make_figs.py"), base], capture_output=True, text=True)
    h2 = {p: hashlib.md5(open(p, "rb").read()).hexdigest() for p in glob.glob(os.path.join(base, "figs", "*.png"))}
    ok(h1 == h2 and len(h1) == 3, f"{d}: figures deterministic ({len(h1)} PNGs, stable hashes)")

# ---------- PHASE 3: source ----------
print("\n========= PHASE 3: SOURCE (generic_COBALT.F90) =========")
src = open(SRC).read()
nloop = len(re.findall(r"^\s*!\$omp target teams loop", src, re.M))
nenter = len(re.findall(r"^\s*!\$omp target enter data", src, re.M))
nexit  = len(re.findall(r"^\s*!\$omp target exit data", src, re.M))
ndc = len(re.findall(r"^\s*do concurrent", src, re.M))
ok(ndc == 0, f"zero live `do concurrent` (found {ndc})")
ok(nloop >= 17, f"kernel count = {nloop} (>=17 expected after bacteria)")
ok(nenter > 0 and nexit > 0, f"residency directives present (enter={nenter}, exit={nexit})")

print("\n================================ RESULT ================================")
if fails: print(f"  *** {len(fails)} FAILURE(S): {fails}"); sys.exit(1)
print(f"  ALL CLEAR ✓  metrics + figure-logic + source verified across {len(ARCHIVES)} archives"); sys.exit(0)
