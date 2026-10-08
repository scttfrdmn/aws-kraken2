#!/usr/bin/env python3
"""E1 consistency from a cohort's outputs.tsv (run-multi's listing of <prefix>/out/: key,
VersionId, size, ETag): every variant of a sample must have one ETag per output file. Every
variant writes with the same part layout (8 MiB parts; the report one PutObject), so equal
ETags mean equal bytes.

  e1_consistency.py COHORT_DIR   -> COHORT_DIR/tables/consistency.tsv; exit 1 if inconsistent

It also asserts E1's variant counts: the one sample in the c1-* invocations has 3 + 5 = 8
variants per file (c1-striped-sdk, c1-striped-cli, c1-parallel-sdk, and c10's 5 batches), every
other sample 5 (c10 only). Exit 1 on any other count: a missing variant is not consistency.
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
C1, BATCHES = 3, 5
c1 = {s for (s, _), vs in groups.items() if any(v.startswith("c1-") for v, _, _ in vs)}
wrongn = 0
if len(c1) != 1:
    print(f"consistency: {len(c1)} samples in the c1 invocations (want 1): {sorted(c1)}", file=sys.stderr)
    wrongn += 1
for (sample, f), vs in sorted(groups.items()):
    want = C1 + BATCHES if sample in c1 else BATCHES
    if len(vs) != want:
        print(f"consistency: {sample} {f}: {len(vs)} variants (want {want})", file=sys.stderr)
        wrongn += 1
print(f"consistency: variant counts {'ok' if not wrongn else f'{wrongn} wrong'} "
      f"({C1 + BATCHES} for the c1 sample, {BATCHES} for the others)")
print(f"consistency: {len(groups)} sample files, {bad} inconsistent -> {d}/tables/consistency.tsv")
sys.exit(1 if bad or wrongn else 0)
