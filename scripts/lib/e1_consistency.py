#!/usr/bin/env python3
"""E1 consistency from a cohort's outputs.tsv (run-multi's listing of <prefix>/out/: key,
VersionId, size, ETag): every variant of a sample must have one ETag per output file. Every
variant writes with the same part layout (8 MiB parts; the report one PutObject), so equal
ETags mean equal bytes.

  e1_consistency.py COHORT_DIR   -> COHORT_DIR/tables/consistency.tsv; exit 1 if inconsistent
"""
import collections, csv, os, sys

d = sys.argv[1]
rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(d, "outputs.tsv")) if l.strip()]
groups = collections.defaultdict(list)
for key, version, size, etag in rows:
    parts = key.split("/")
    inv, variant, f = parts[-3], parts[-2], parts[-1]
    sample = variant.split("-", 1)[1]
    groups[(sample, f)].append((inv + "/" + variant, etag, int(size)))
os.makedirs(os.path.join(d, "tables"), exist_ok=True)
bad = 0
with open(os.path.join(d, "tables", "consistency.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["sample", "file", "variants", "distinct_etags", "sizes", "consistent", "variant_list"])
    for (sample, f), vs in sorted(groups.items()):
        etags = {e for _, e, _ in vs}
        ok = len(etags) == 1
        bad += not ok
        w.writerow([sample, f, len(vs), len(etags), ",".join(sorted({str(s) for _, _, s in vs})),
                    "yes" if ok else "no", " ".join(sorted(v for v, _, _ in vs))])
print(f"consistency: {len(groups)} sample files, {bad} inconsistent -> {d}/tables/consistency.tsv")
sys.exit(1 if bad else 0)
