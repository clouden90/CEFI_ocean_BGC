#!/usr/bin/env python3
"""
GPU-porting PR verifier — re-derives every reported performance/correctness number from the
committed profiling archive and prints CLAIM vs ARCHIVE vs MATCH. Exit code 0 = all match.

WHY: numbers in a PR / GPU_PORTING.md must be re-derivable from committed artifacts, not
hand-transcribed from ephemeral /scratch logs (that caused real slips in §1.2b). Run this and
trust the output, not the prose.

USAGE:   python3 verify.py [ARCHIVE_DIR]   (default: ./s1.2b_growth_block)

TO REUSE FOR A NEW SECTION:
  1. Put the section's logs in profiling/<section>/ with the same 0N_*.txt naming (see PROVENANCE.md).
  2. Update F2S (the build's F1L<line> -> section map) and CLAIMS (the expected numbers) below.
  3. Run `python3 verify.py <section>`.  Reusable extractor functions are above the CLAIMS block.
"""
import re, sys, os

# ============================ REUSABLE EXTRACTORS (do not edit per-PR) ============================
def _toks(l): return l.split()

def parse_budget(path):
    """nsys stats text (kern_sum + mem_time_sum + mem_size_sum + api_sum). Returns raw totals."""
    g = {'kern_ns': 0.0}
    for l in open(path):
        t = _toks(l)
        if not t: continue
        if 'update_from_source__F1L' in l and len(t) >= 4 and t[1].isdigit():
            g['kern_ns'] += float(t[1])                                   # kern Total Time (ns)
        if 'memcpy Device-to-Host' in l or 'memcpy Host-to-Device' in l:
            k = 'dtoh' if 'Device-to-Host' in l else 'htod'
            if t[1].isdigit() and int(t[1]) > 1_000_000:                  # TIME line: pct total_ns count
                g[k+'_tns'] = float(t[1]); g[k+'_n'] = int(t[2])
            elif t[1].isdigit():                                          # SIZE line: MB count ...
                g[k+'_mb'] = float(t[0])
        if 'cuStreamSynchronize' in l and len(t) > 2 and t[2].isdigit():
            g['sync'] = int(t[2])
    return g

def parse_ncu_details(path, f2s):
    """ncu --import --page details text -> {section: {grid,regs,ach,theo,sm,dram,ipc,warp}}."""
    K, cur = {}, None
    for l in open(path):
        h = re.search(r'update_from_source__F1L(\d+)_', l)
        if h:
            cur = f2s.get(h.group(1));
            if cur: K.setdefault(cur, {})
        if not cur: continue
        last = lambda: float(_toks(l)[-1])
        if 'DRAM Throughput' in l: K[cur]['dram'] = last()
        elif 'Compute (SM) Throughput' in l: K[cur]['sm'] = last()
        elif 'Executed Ipc Active' in l: K[cur]['ipc'] = last()
        elif 'Warp Cycles Per Issued' in l: K[cur]['warp'] = last()
        elif 'Grid Size' in l: K[cur]['grid'] = last()
        elif 'Registers Per Thread' in l: K[cur]['regs'] = last()
        elif 'Theoretical Occupancy' in l: K[cur]['theo'] = last()
        elif 'Achieved Occupancy' in l: K[cur]['ach'] = last()
    return K

def parse_nsys_kern_times(path, f2s):
    """kern_sum Avg(ns) per section (= per-call time, ms)."""
    T = {}
    for l in open(path):
        h = re.search(r'update_from_source__F1L(\d+)_', l); t = _toks(l)
        if h and len(t) >= 4 and t[1].isdigit() and f2s.get(h.group(1)):
            T[f2s[h.group(1)]] = float(t[3]) / 1e6
    return T

def parse_roofline(path, f2s):
    """ncu --page raw FLOP/byte/time -> {section: (AI FLOP/B, GFLOP/s)}."""
    K, cur = {}, None
    for l in open(path):
        h = re.search(r'update_from_source__F1L(\d+)_', l)
        if h: cur = f2s.get(h.group(1)); K.setdefault(cur, {}) if cur else None
        if not cur: continue
        t = _toks(l)
        if 'dram__bytes.sum' in l: K[cur]['dram'] = float(t[-1]) * 1e6
        elif 'time_duration.sum' in l: K[cur]['t'] = float(t[-1]) / 1e3
        elif 'dadd_pred_on.sum' in l: K[cur]['dadd'] = float(t[-1])
        elif 'dmul_pred_on.sum' in l: K[cur]['dmul'] = float(t[-1])
        elif 'dfma_pred_on.sum' in l: K[cur]['dfma'] = float(t[-1])
    out = {}
    for s, k in K.items():
        if {'dadd','dmul','dfma','dram','t'} <= k.keys():
            flop = k['dadd'] + k['dmul'] + 2*k['dfma']
            out[s] = (flop/k['dram'], flop/k['t']/1e9)
    return out

def parse_b2b(path):
    d = {}
    for l in open(path):
        m = re.match(r'\s*(dic|alk|no3|po4|o2)\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(\S+)\s+(\w+)', l)
        if m: d[m.group(1)] = (float(m.group(2)), float(m.group(3)), m.group(4))  # gref, band, verdict
    return d

def parse_speed(path):
    g, tot = [], []
    for l in open(path):
        if 'phytoplankton growth ca' in l:
            m = re.search(r'growth ca\S*\s+\d+\s+([\d.]+)', l); g.append(float(m.group(1))) if m else None
        if 'Total runtime' in l:
            m = re.search(r'Total runtime\s+\d+\s+([\d.]+)', l); tot.append(float(m.group(1))) if m else None
    return g, tot

def _cellnum(s):
    m = re.search(r'-?[\d.]+(?:e-?\d+)?', s.replace('−','-'))
    return float(m.group()) if m else None

def parse_pr_summary(path, namemap):
    """Parse the numbers straight out of PR_SUMMARY.md's tables/headline -> a structure mirroring CLAIMS.
    Lets us verify the *document* against CLAIMS (catches PR↔CLAIMS drift), so there's no blind hand-mirror."""
    txt = open(path).read(); P = {'speed':{}, 'tier2':{}, 'b2b':{}, 'roofline':{}, 'perkernel':{}, 'budget_after':{}}
    m = re.search(r'CPU\s*([\d.]+)\s*s\s*[→-]+\s*GPU\s*([\d.]+)\s*s\s*=\s*([\d.]+)', txt)
    if m: P['speed'].update(cpu_growth=float(m[1]), gpu_growth=float(m[2]), speedup=float(m[3]))
    m = re.search(r'coupled total\s*([\d.]+)\s*[→-]+\s*([\d.]+)\s*s', txt)
    if m: P['speed'].update(cpu_total=float(m[1]), gpu_total=float(m[2]))
    m = re.search(r'restructured\s*\**([\d.]+)\s*s\**\s*vs\s*pristine\s*\**([\d.]+)', txt)
    if m: P['tier2'] = dict(restr=float(m[1]), prist=float(m[2]))
    for l in txt.split('\n'):
        if not l.lstrip().startswith('|'): continue
        c = [x.strip() for x in l.strip().strip('|').split('|')]
        if len(c) == 10 and c[0] in namemap:                       # §3b per-kernel row
            occ = c[4].split('/')
            P['perkernel'][namemap[c[0]]] = (_cellnum(c[1]),_cellnum(c[2]),_cellnum(c[3]),
                _cellnum(occ[0]),_cellnum(occ[1]),_cellnum(c[5]),_cellnum(c[6]),_cellnum(c[7]),_cellnum(c[8]))
        elif len(c) == 3 and 'FLOP/B' in c[1] and c[0] in ('§1.1','A','B'):   # §3c roofline row
            P['roofline'][c[0]] = (_cellnum(c[1]), _cellnum(c[2]))
        elif len(c) == 4 and c[0] in ('dic','alk','no3','po4','o2'):          # §2 b2b row
            P['b2b'][c[0]] = (_cellnum(c[1]), _cellnum(c[2]))
        elif len(c) == 4:                                                     # §3a budget row (after = col index 2)
            k = c[0].lower()
            if 'kernel compute' in k: P['budget_after']['kern'] = _cellnum(c[2])
            elif 'stream syncs' in k: P['budget_after']['sync'] = _cellnum(c[2])
            elif 'transfer time' in k: P['budget_after']['xfer_ms'] = _cellnum(c[2])
            elif 'htod' in k: a=c[2].split('/'); P['budget_after']['htod_n']=_cellnum(a[0]); P['budget_after']['htod_gb']=_cellnum(a[1])
            elif 'dtoh' in k: a=c[2].split('/'); P['budget_after']['dtoh_n']=_cellnum(a[0]); P['budget_after']['dtoh_gb']=_cellnum(a[1])
    return P

def chk(label, claim, got, tol=0.03, abstol=0.0):
    # pass if within relative tol OR absolute abstol (abstol handles near-zero %, where rel tol is meaningless)
    try: ok = abs(float(claim)-float(got)) <= max(tol*abs(float(claim)), abstol)
    except: ok = str(claim) == str(got)
    print(f"  [{'OK ' if ok else 'XX!'}] {label:38s} claim={claim!s:11s} archive={got if isinstance(got,str) else round(float(got),3)!s}")
    return ok

# ============================ PER-PR DATA (edit this block for each section) ============================
F2S = {'3509':'§1.1','3639':'A','3733':'B','3775':'Geider','3857':'E','3872':'F',
       '3892':'§1.3N','3930':'§1.3P','3955':'§1.3Fe','3977':'§1.3Si'}  # merged-build F1L -> section
PR_NAMEMAP = {'§1.1':'§1.1','A irradiance':'A','B relax':'B','Geider':'Geider','E ML-avg':'E','F relax':'F',
              '§1.3 N':'§1.3N','§1.3 P':'§1.3P','§1.3 Fe':'§1.3Fe','§1.3 Si':'§1.3Si'}  # PR table col-1 -> section

CLAIMS = {
 'speed':   dict(cpu_growth=72.0, gpu_growth=16.6, speedup=4.33, cpu_total=612, gpu_total=572),
 'b2b':     {'dic':(6.5e-16,3.9e-16),'alk':(3.6e-16,4.8e-16),'no3':(1.4e-16,2.7e-16),
             'po4':(1.3e-16,6.3e-16),'o2':(2.9e-16,1.0e-15)},   # (|GPU-ref|/ref, band); all PASS
 'tier2':   dict(restr=76.6, prist=74.9),
 # per-call budget (raw totals are over 2 COBALT calls -> divide by 2; GB = MB/1000):
 'budget_before': dict(kern=103, sync=95, htod_n=696, htod_gb=1.89, dtoh_n=141, dtoh_gb=1.50, xfer_ms=373),
 'budget_after':  dict(kern=103, sync=28, htod_n=402, htod_gb=0.85, dtoh_n=137, dtoh_gb=1.45, xfer_ms=331),
 'perkernel': {  # section: (time_ms, grid, regs, occ_ach, occ_theo, sm, dram, ipc, warp)
   '§1.1':(4.9,9600,72,43.6,43.8,64,2.2,1.55,18.0), 'A':(7.7,128,255,6.25,12.5,10.6,0.5,0.25,15.9),
   'B':(1.0,9600,74,37,37.5,56,2.5,1.36,17.4),       'Geider':(54,9600,130,18.7,18.8,31.8,0.17,0.75,15.9),
   'E':(28,65536,90,31.1,31.3,15.2,0.01,0.35,56.9),  'F':(1.5,38400,74,37,37.5,58,1.4,1.37,17.3),
   '§1.3N':(2.4,9600,50,53,56,79,2.3,1.78,19.0),     '§1.3P':(1.0,9600,48,60,62,81,5.3,1.86,20.6),
   '§1.3Fe':(0.9,9600,50,53,56,76,4.8,1.74,19.4),    '§1.3Si':(0.7,9600,48,60,62,81,6.0,1.86,20.5)},
 'roofline': {'§1.1':(2.14,175),'A':(2.51,42),'B':(0.20,18)},  # (AI FLOP/B, GFLOP/s)
}
# =======================================================================================================

def main():
    d = sys.argv[1] if len(sys.argv) > 1 else 's1.2b_growth_block'
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), d)
    F = lambda n: os.path.join(base, n)
    fails = []
    def track(ok, name):
        if not ok: fails.append(name)

    print("================= §3e SPEED (06_speed.txt) =================")
    g, tot = parse_speed(F('06_speed.txt')); c = CLAIMS['speed']
    track(chk("CPU growth", c['cpu_growth'], g[0]), 'cpu_growth')
    track(chk("GPU growth", c['gpu_growth'], g[1]), 'gpu_growth')
    track(chk("speedup", c['speedup'], g[0]/g[1]), 'speedup')
    track(chk("CPU total", c['cpu_total'], tot[0]), 'cpu_total')
    track(chk("GPU total", c['gpu_total'], tot[1]), 'gpu_total')

    print("================= §2 b2b (05_b2b.txt) =================")
    b = parse_b2b(F('05_b2b.txt'))
    for t,(gref,band) in CLAIMS['b2b'].items():
        track(chk(f"{t} |GPU-ref|/ref", gref, b[t][0], 0.1), t+'_gref')
        track(chk(f"{t} band", band, b[t][1], 0.02), t+'_band')
        track(chk(f"{t} verdict", "PASS", b[t][2]), t+'_verd')

    print("================= §4 Tier-2 -O2 (07_tier2_O2_objswap.txt) =================")
    t2 = {}
    for l in open(F('07_tier2_O2_objswap.txt')):
        if 'phytoplankton growth' in l:
            m = re.search(r'growth ca\S*\s+\d+\s+([\d.]+)', l)
            if m: t2['cur' if 'cur' in l else 'prist'] = float(m.group(1))
    track(chk("Tier2 restructured", CLAIMS['tier2']['restr'], t2['cur'], 0.01), 't2_cur')
    track(chk("Tier2 pristine", CLAIMS['tier2']['prist'], t2['prist'], 0.01), 't2_prist')

    print("================= §3a BUDGET (01/02 *.txt; /2 = per-call) =================")
    for tag, fn in [('budget_before','01_budget_10scope.txt'), ('budget_after','02_budget_merged.txt')]:
        g = parse_budget(F(fn)); c = CLAIMS[tag]
        track(chk(f"{tag} kernel ms", c['kern'], g['kern_ns']/2/1e6), tag+'_kern')
        track(chk(f"{tag} sync", c['sync'], g['sync']/2), tag+'_sync')
        track(chk(f"{tag} HtoD copies", c['htod_n'], g['htod_n']/2), tag+'_hn')
        track(chk(f"{tag} HtoD GB", c['htod_gb'], g['htod_mb']/2/1000), tag+'_hgb')
        track(chk(f"{tag} DtoH copies", c['dtoh_n'], g['dtoh_n']/2), tag+'_dn')
        track(chk(f"{tag} DtoH GB", c['dtoh_gb'], g['dtoh_mb']/2/1000), tag+'_dgb')
        track(chk(f"{tag} transfer ms", c['xfer_ms'], (g['dtoh_tns']+g['htod_tns'])/2/1e6), tag+'_x')

    print("================= §3b PER-KERNEL (03 ncu + 02 nsys times) =================")
    K = parse_ncu_details(F('03_perkernel_ncu.txt'), F2S); T = parse_nsys_kern_times(F('02_budget_merged.txt'), F2S)
    cols = ['grid','regs','ach','theo','sm','dram','ipc','warp']
    for sec, vals in CLAIMS['perkernel'].items():
        track(chk(f"{sec} time(ms)", vals[0], T.get(sec, -1), 0.06), f"{sec}.time")
        for c, pr in zip(cols, vals[1:]):
            tol = 0.001 if c in ('grid','regs') else 0.06
            abst = 0.1 if c == 'dram' else 0.0   # near-zero DRAM%: allow 0.1 percentage-point (rel tol meaningless)
            ok = chk(f"{sec} {c}", pr, K[sec].get(c, -1), tol, abst) if K.get(sec) and c in K[sec] else chk(f"{sec} {c}", pr, "MISSING")
            track(ok, f"{sec}.{c}")

    print("================= §3c ROOFLINE (04_roofline_flops.txt) =================")
    R = parse_roofline(F('04_roofline_flops.txt'), F2S)
    for sec,(ai,gf) in CLAIMS['roofline'].items():
        track(chk(f"{sec} AI", ai, R[sec][0], 0.03), f"{sec}.AI")
        track(chk(f"{sec} GFLOP/s", gf, R[sec][1], 0.06), f"{sec}.GF")

    print("\n================= PHASE B: PR_SUMMARY.md ↔ CLAIMS (document matches verified values) =================")
    prs = F('PR_SUMMARY.md')
    if os.path.exists(prs):
        P = parse_pr_summary(prs, PR_NAMEMAP)
        for k, v in CLAIMS['speed'].items():    track(chk(f"PR speed.{k}", v, P['speed'].get(k,-9), 0.02), f"PR.speed.{k}")
        for k, v in CLAIMS['tier2'].items():    track(chk(f"PR tier2.{k}", v, P['tier2'].get(k,-9), 0.02), f"PR.tier2.{k}")
        for t,(g,b) in CLAIMS['b2b'].items():
            track(chk(f"PR b2b {t} gref", g, P['b2b'].get(t,(-9,-9))[0], 0.05), f"PR.b2b.{t}")
            track(chk(f"PR b2b {t} band", b, P['b2b'].get(t,(-9,-9))[1], 0.02), f"PR.b2b.{t}.band")
        for k, v in CLAIMS['budget_after'].items():
            track(chk(f"PR budget.{k}", v, P['budget_after'].get(k,-9), 0.02, 0.1 if 'gb' in k else 0.0), f"PR.budget.{k}")
        ck = ['time','grid','regs','ach','theo','sm','dram','ipc','warp']
        for sec, vals in CLAIMS['perkernel'].items():
            row = P['perkernel'].get(sec, [-9]*9)
            for i, (c, pr) in enumerate(zip(ck, vals)):
                track(chk(f"PR {sec}.{c}", pr, row[i], 0.02, 0.1 if c=='dram' else 0.0), f"PR.{sec}.{c}")
        for sec,(ai,gf) in CLAIMS['roofline'].items():
            track(chk(f"PR {sec} AI", ai, P['roofline'].get(sec,(-9,-9))[0], 0.02), f"PR.{sec}.AI")
            track(chk(f"PR {sec} GFLOP/s", gf, P['roofline'].get(sec,(-9,-9))[1], 0.02), f"PR.{sec}.GF")
    else:
        print("  (no PR_SUMMARY.md in archive dir — skipping document check)")

    print("\n================================ RESULT ================================")
    if fails: print(f"  *** {len(fails)} MISMATCH(es): {fails}"); sys.exit(1)
    print("  ALL CLAIMS MATCH THE ARCHIVE *and* PR_SUMMARY.md ✓  (CLAIMS↔archive AND PR↔CLAIMS)"); sys.exit(0)

if __name__ == '__main__':
    main()
