#!/usr/bin/env python3
"""Op histories for upstream/umap_order.cc (#44; docs/hitorder.md): the golden data a HitCounts
implementation (internal/classify/hitorder.go) is tested against.

  umap_cmds.py OUTDIR    -> OUTDIR/ops-<k>.txt

Each file is one map's lifetime as one classify.cc thread uses hit_counts: per read, C (clear);
I <taxon> for each hit in hit order (repeats included); P (print the order); L <taxon> (the
ResolveTree lookup of one taxon: present, absent, or 0); P. Sessions differ in read sizes and
taxon ranges (up to 2^31, and RODA v205's internal ID range). Seeded: reproducible.
"""
import os, random, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
sessions = [(1, 1500, 1, 12, 3_000_000), (2, 600, 1, 60, 3_000_000), (3, 60, 1, 600, 2**31 - 1),
            (4, 2000, 1, 6, 400), (5, 150, 20, 200, 3_000_000), (6, 600, 1, 40, 60),
            (7, 300, 1, 30, 2_158_558)]
for sid, reads, lo, hi, kmax in sessions:
    rng = random.Random(44000 + sid)
    with open(os.path.join(out, f"ops-{sid}.txt"), "w") as f:
        for _ in range(reads):
            f.write("C\n")
            n = rng.randint(lo, hi)
            keys = [rng.randint(1, kmax) for _ in range(n)]
            seq = []
            for k in keys:
                seq += [k] * rng.choice((1, 1, 1, 2, 5))
            rng.shuffle(seq)
            for k in seq:
                f.write(f"I {k}\n")
            f.write("P\n")
            look = rng.choice([0, rng.randint(1, kmax), rng.choice(seq)])
            f.write(f"L {look}\n")
            f.write("P\n")
print(f"umap_cmds: {len(sessions)} sessions -> {out}")
