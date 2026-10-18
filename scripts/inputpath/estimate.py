#!/usr/bin/env python3
"""Wall-time estimate of one input-path sweep session (docs/inputpath.md, "Time budget"; #90).

Usage: estimate.py --engine upstream|ours --ttl-min M [--reps 2] [--threads "48 32 16"] [--ps "16 8 4 2"]
                   [--chunks "8192 16384"] [--thp-contrast 0|1] [--pipe-contrast 0|1]
                   [--pe-fq-gb 12.8] [--se-fq-gb 6.4] [--nproc 64]

A model, not a measurement: it sizes the TTL and says whether the matrix fits. Its rates come
from committed records (each cited below); the sample sizes are assumptions until inputs.tsv names
the samples (default: SRR062634 in full, 24.5 M pairs, 2 x 6.4 GB FASTQ, as the paired-end sample
and one 6.4 GB mate as the single-end one). Per point: max(classification, decode) + overhead.
  classification  FASTQ bytes / (CLASSIFY_BPS x T x EFF): upstream on Standard-8, 200,000 pairs
                  (103.8 MB FASTQ) in 0.188 s at T = 8 on r8g.2xlarge
                  (results/g2/20261006-100409-16bc8b0, loadbench pe warm): 69 MB/s per thread; EFF
                  0.8 for upstream's critical sections at T >= 16 (assumed)
  gzip -dc        194-237 MB/s of FASTQ per stream on Graviton (results/g2/*/log/run.log
                  "gzip -dc rate"): GZIP_BPS 200 MB/s, one stream per mate in parallel
  rapidgzip       -P 16 and -P 8 decoded SRR5935773's ~7.5 GB in 2.74 s and 5.05 s on c8g.4xlarge
                  (results/g3/20261009-060042-b6e1265/tables/probe-decomp.tsv): RG_BPS 170 MB/s per
                  thread, capped where p x mates + T exceeds the vCPUs
  identity        one decode to sha256sum per configuration and file, bounded by SHA_BPS 1.8 GB/s
  overhead        OVERHEAD_S per point (load from tmpfs, sha256 of --output, pushes); ours adds
                  OURS_LOAD_S (its table is read into RAM per run)
  setup           SETUP_MIN: dnf, clone, build, rapidgzip, DB and inputs staged and checked
"""
import argparse

CLASSIFY_BPS, EFF, GZIP_BPS, RG_BPS, SHA_BPS = 69e6, 0.8, 200e6, 170e6, 1.8e9
OVERHEAD_S, OURS_LOAD_S, SETUP_MIN, WRAP_MIN = 6.0, 4.0, 12.0, 3.0


def point_s(fq, mates, arm, t, p, nproc, engine):
    cls = fq / (CLASSIFY_BPS * t * EFF)
    mate = fq / mates
    if arm == "I0":
        dec = 0
    elif arm == "I1":
        dec = mate / GZIP_BPS
    else:
        free = max(1, nproc - t)
        eff_p = min(p, max(1, free // mates)) if p * mates + t > nproc else p
        dec = mate / (RG_BPS * eff_p)
    return max(cls, dec) + OVERHEAD_S + (OURS_LOAD_S if engine == "ours" else 0)


def sample_points(a, fq, mates, best_p):
    pts = []
    for t in a.threads:
        pts.append(("I0", t, None))
    if a.thp_contrast:
        pts += [("I0", t, None) for t in a.threads]
    pts += [("I2", t, p) for p in a.ps for t in a.threads]
    pts += [("I3", t, best_p) for t in a.threads] + [("I4", t, best_p) for t in a.threads]
    pts += [("I2", t, best_p) for _ in a.chunks for t in a.threads]
    if a.pipe_contrast:
        pts += [("I2", t, best_p) for t in a.threads]
    pts += [("I1", t, None) for t in a.threads] * (2 if a.engine == "ours" else 1)
    return pts


def run(a):
    out, total_s, n = [], 0.0, 0
    ident_s = 0.0
    for name, fq, mates in (("se", a.se_fq_gb * 1e9, 1), ("pe", a.pe_fq_gb * 1e9, 2)):
        best_p = 8
        pts = sample_points(a, fq, mates, best_p)
        s = sum(point_s(fq, mates, arm, t, p, a.nproc, a.engine) for arm, t, p in pts)
        s += point_s(fq, mates, "I0", max(a.threads), None, a.nproc, a.engine)   # the warm-up
        cfgs = list(a.ps) + [best_p] * (len(a.chunks) + 2)
        ident_s += sum(mates * max(fq / mates / (RG_BPS * p), fq / mates / SHA_BPS) + 2 for p in cfgs)
        out.append((name, len(pts), s))
        total_s += s
        n += len(pts)
    meas = total_s * a.reps
    tot_min = SETUP_MIN + ident_s / 60 + meas / 60 + WRAP_MIN
    return out, n, ident_s, meas, tot_min


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=("upstream", "ours"), required=True)
    ap.add_argument("--ttl-min", type=float, required=True)
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--threads", default="48 32 16")
    ap.add_argument("--ps", default="16 8 4 2")
    ap.add_argument("--chunks", default="8192 16384")
    ap.add_argument("--thp-contrast", type=int, default=1)
    ap.add_argument("--pipe-contrast", type=int, default=1)
    ap.add_argument("--pe-fq-gb", type=float, default=12.8)
    ap.add_argument("--se-fq-gb", type=float, default=6.4)
    ap.add_argument("--nproc", type=int, default=64)
    a = ap.parse_args()
    a.threads = [int(x) for x in a.threads.split()]
    a.ps = [int(x) for x in a.ps.split()]
    a.chunks = [int(x) for x in a.chunks.split()]
    out, n, ident_s, meas, tot = run(a)
    for name, k, s in out:
        print(f"estimate: {name}: {k} points + warm-up, {s / 60:.1f} min per rep")
    fits = tot <= a.ttl_min
    print(f"estimate: {n} points x {a.reps} reps; setup {SETUP_MIN:.0f} + identity {ident_s / 60:.1f} + measure {meas / 60:.1f} "
          f"+ wrap-up {WRAP_MIN:.0f} = {tot:.0f} min against a {a.ttl_min:.0f} min TTL: {'fits' if fits else 'DOES NOT FIT'}"
          f" ({'margin' if fits else 'over by'} {abs(a.ttl_min - tot):.0f} min)")
    for f in (1.5, 2.0):
        t2 = SETUP_MIN + f * (ident_s / 60 + meas / 60) + WRAP_MIN
        print(f"estimate: at {f:.1f}x the modelled point times: {t2:.0f} min ({'fits' if t2 <= a.ttl_min else 'does not fit: the deadline skips the tail of rep 2'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
