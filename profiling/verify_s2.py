#!/usr/bin/env python3
"""
verify_s2.py — machine-verify every §2 (foodweb) metric I reported against the committed archives.

Companion to verify.py (which covers §1.2b). Re-parses s2_production/ and s2_zoo/ using make_figs.py's
parsers (same CSVs/logs the figures are built from) and asserts the reported headline + per-kernel + roofline
+ b2b numbers match. Re-runnable: `python3 verify_s2.py`. Exit 0 = all claims match the archive.

This closes the trust gap: §2 numbers were documented in PROVENANCE.md and traced by hand, but not
machine-checked. Now they are.
"""
import os, re, sys, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
# import make_figs.py's parsers (DRY — same parse the figures use)
spec = importlib.util.spec_from_file_location("make_figs", os.path.join(HERE, "make_figs.py"))
mf = importlib.util.module_from_spec(spec); spec.loader.exec_module(mf)

fails = []
def chk(label, claim, got, tol=0.02, abstol=0.0):
    ok = got is not None and abs(claim - got) <= max(tol*abs(claim), abstol)
    print(f"  [{'OK ' if ok else 'XX!'}] {label:34s} claim={claim:<12g} archive={got}")
    if not ok: fails.append(label)
    return ok

def parse_b2b(path):
    """05_b2b.txt -> {tracer: (gpu_ref_diff, band, verdict_pass)}."""
    out = {}
    for ln in open(path):
        m = re.match(r"\s*(dic|alk|no3|po4|o2)\s+[\d.eE+-]+\s+[\d.eE+-]+\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+(PASS|FAIL)", ln)
        if m: out[m.group(1)] = (float(m.group(3)), float(m.group(4)), m.group(5) == "PASS")
    return out

# ============================ CLAIMS (what I reported in chat / commits / PROVENANCE) ============================
PROD = {
  "dir": "s2_production",
  "speed": {"production loop": (16.54, 2.11, 7.84)},          # cpu, gpu, speedup
  "kernels": [{"tag": "production", "Grid Size": 9600, "Registers Per Thread": 74,
             "Achieved Occupancy": 36.45, "Theoretical Occupancy": 37.50,
             "Compute (SM) Throughput": 54.55, "DRAM Throughput": 2.0,
             "Executed Ipc Active": 1.28, "Warp Cycles Per Issued Instruction": 18.31, "L2 Hit Rate": 60.0}],
  "roofline": {"production": (0.24, 17.6)},                   # AI, GFLOP/s
  "b2b": {"dic": 6.49e-16, "alk": 3.60e-16, "no3": 1.35e-16, "po4": 1.27e-16, "o2": 2.91e-16},
}
ZOO = {
  "dir": "s2_zoo",
  "speed": {"zooplankton": (14.58, 1.74, 8.37)},
  "kernels": [{"tag": "zoo", "Grid Size": 9600, "Registers Per Thread": 136,
             "Achieved Occupancy": 18.63, "Theoretical Occupancy": 18.75,
             "Compute (SM) Throughput": 29.23, "DRAM Throughput": 1.59,
             "Executed Ipc Active": 0.70, "Warp Cycles Per Issued Instruction": 17.03, "L2 Hit Rate": 89.34}],
  "roofline": {"zoo": (None, None)},                          # not separately reported; skip values, just presence
  "b2b": {"dic": 1.30e-16, "alk": 3.60e-16, "no3": 0.0, "po4": 2.53e-16, "o2": 1.45e-16},
}
LOSSES = {
  "dir": "s2_losses",
  "speed": {"other losses": (11.99, 2.81, 4.27)},
  "kernels": [{"tag": "losses", "Grid Size": 9600, "Registers Per Thread": 56,
               "Achieved Occupancy": 53.49, "Theoretical Occupancy": 56.25,
               "Compute (SM) Throughput": 75.36, "DRAM Throughput": 3.47, "Executed Ipc Active": 1.72},
              {"tag": "losses2D", "Grid Size": 128, "Registers Per Thread": 56,
               "Achieved Occupancy": 6.23, "Compute (SM) Throughput": 8.13,
               "DRAM Throughput": 0.23, "Executed Ipc Active": 0.22}],
  "roofline": {"losses": (None, None)},
  "b2b": {"dic": 1.30e-16, "alk": 3.60e-16, "no3": 0.0, "po4": 2.53e-16, "o2": 1.45e-16},
}

def verify(C):
    base = os.path.join(HERE, C["dir"])
    print(f"\n========== {C['dir']} ==========")
    det  = mf.parse_details(mf._find(base, "*full*.csv"))
    roof = mf.parse_roof(mf._find(base, "*perkernel*budget*.txt", "03_*.txt"))
    speed = mf.parse_speed(mf._find(base, "*speed*.txt", "06_*.txt"))
    b2b  = parse_b2b(mf._find(base, "*b2b*.txt", "05_*.txt"))

    # speed
    for sec, (cpu, gpu, sp) in C["speed"].items():
        a = speed.get(sec)
        chk(f"speed {sec} CPU", cpu, a[0] if a else None)
        chk(f"speed {sec} GPU", gpu, a[1] if a else None)
        chk(f"speed {sec} speedup", sp, (a[0]/a[1]) if a else None, tol=0.03)
    # per-kernel ncu (one or more kernels per archive)
    for k in C["kernels"]:
        tag = k["tag"]; d = det.get(tag, {})
        for metric, claim in k.items():
            if metric == "tag": continue
            abst = 0.15 if metric == "DRAM Throughput" else (0.1 if "Occupancy" in metric or metric=="L2 Hit Rate" else 0.0)
            chk(f"{tag}.{metric}", claim, d.get(metric), tol=0.02, abstol=abst)
    # roofline (skip if value None — just assert presence)
    for tag, (ai, gf) in C["roofline"].items():
        if ai is None:
            print(f"  [{'OK ' if tag in roof else 'XX!'}] roofline {tag} present       archive={'yes' if tag in roof else 'MISSING'}")
            if tag not in roof: fails.append(f"roofline {tag} present")
        else:
            r = roof.get(tag); chk(f"roofline {tag} AI", ai, r[0] if r else None); chk(f"roofline {tag} GFLOP/s", gf, r[1] if r else None)
    # b2b (value match + PASS verdict)
    for tr, claim in C["b2b"].items():
        a = b2b.get(tr)
        got = a[0] if a else None
        ok = got is not None and (abs(claim-got) <= max(0.05*abs(claim), 1e-17)) and a[2]
        print(f"  [{'OK ' if ok else 'XX!'}] b2b {tr} (val+PASS)          claim={claim:<12g} archive={got} pass={a[2] if a else None}")
        if not ok: fails.append(f"b2b {tr}")

verify(PROD)
verify(ZOO)
verify(LOSSES)
print("\n================================ RESULT ================================")
if fails: print(f"  *** {len(fails)} MISMATCH(es): {fails}"); sys.exit(1)
print("  ALL §2 REPORTED METRICS MATCH THE COMMITTED ARCHIVE ✓"); sys.exit(0)
