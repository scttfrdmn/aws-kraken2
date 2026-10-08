#!/usr/bin/env python3
"""U1's tables (runs/g3-u1-*.json; scripts/g3/u1.body.sh), from the record only.

  u1_tables.py RUN_DIR   -> RUN_DIR/tables/{rungs,samples,drift,law1-crosscheck}.tsv

rungs.tsv: per rung (u1-rung lines): input, threads, processes, cohort, pass wall (the fq rungs:
the sum of their samples' walls, fq preparation excluded), pairs, Mpairs/s, and the per-sample
classify ("processed in") and wall medians; per cohort-1 cell (A: input, T) the median, min and
max over its n = 3 reps.
samples.tsv: every u1-sample line.
drift.tsv: the reference rung (sample 1, fq, T = 96) at each point of the run.
law1-crosscheck.tsv: for the C-c100-fq-t96 rung (which computed the engine's S3 ETag of every
upstream output and report), each sample against every E2 cohort under results/g3/ (cohort.json
spec runs/g3-e2-*): every variant of the sample there must carry upstream's ETag. Exit 1 if any
sample failed in U1 or any compared ETag differs.
"""
import collections, csv, glob, json, os, statistics, sys

d = os.path.normpath(sys.argv[1])
T = os.path.join(d, "tables")
os.makedirs(T, exist_ok=True)
L = [json.loads(l) for l in open(os.path.join(d, "out", "u1.jsonl")) if l.strip()]
S = [x for x in L if x["kind"] == "sample"]
R = [x for x in L if x["kind"] == "rung"]


def w(name, head, body):
    with open(os.path.join(T, name), "w", newline="") as fh:
        x = csv.writer(fh, delimiter="\t", lineterminator="\n")
        x.writerow(head)
        x.writerows(body)


med = lambda xs: f"{statistics.median(xs):.3f}" if xs else "-"
w("samples.tsv", ["rung", "input", "threads", "sample", "pairs", "exit", "wall_s", "classify_s", "output_etag", "report_etag"],
  [[x["rung"], x["input"], x["threads"], x["sample"], x["pairs"], x["exit"], f"{x['wall_s']:.3f}",
    x["classify_s"] if x["classify_s"] is not None else "-", x["output_etag"], x["report_etag"]] for x in S])
rows = []
for r in R:
    ss = [x for x in S if x["rung"] == r["rung"]]
    pairs = sum(x["pairs"] for x in ss)
    rows.append([r["rung"], r["input"], r["threads"], r["procs"], r["cohort"], len(ss), sum(x["exit"] != 0 for x in ss),
                 f"{r['pass_wall_s']:.2f}", pairs, f"{pairs / r['pass_wall_s'] / 1e6:.3f}",
                 med([x["classify_s"] for x in ss if x["classify_s"] is not None]), med([x["wall_s"] for x in ss])])
cells = collections.defaultdict(list)
for x in S:
    if x["rung"].startswith("A-c1-"):
        cells[(x["input"], x["threads"])].append(x["wall_s"])
for (inp, t), ws in sorted(cells.items()):
    pairs = S[0]["pairs"] if S else 0
    rows.append([f"A-c1-{inp}-t{t} (n={len(ws)})", inp, t, 1, 1, len(ws), 0, f"{statistics.median(ws):.2f}", pairs,
                 f"{pairs / statistics.median(ws) / 1e6:.3f}", "-", f"{min(ws):.3f}-{max(ws):.3f}"])
w("rungs.tsv", ["rung", "input", "threads", "procs", "cohort", "samples", "failed", "pass_wall_s", "pairs", "Mpairs_per_s",
                "classify_s_median", "wall_s_median_or_range"], rows)
w("drift.tsv", ["rung", "start", "wall_s", "classify_s"],
  [[x["rung"], f"{x['start']:.0f}", f"{x['wall_s']:.3f}", x["classify_s"]] for x in S if x["rung"].startswith("ref")])

up = {x["sample"]: x for x in S if x["rung"] == "C-c100-fq-t96"}
cmp, bad = [], 0
for cj in sorted(glob.glob(os.path.join(os.path.dirname(d), "*", "cohort.json"))):
    c = json.load(open(cj))
    if not str(c.get("spec", "")).startswith("runs/g3-e2-"):
        continue
    o = os.path.join(os.path.dirname(cj), "outputs.tsv")
    if not os.path.exists(o):
        continue
    for l in open(o):
        if not l.strip():
            continue
        key, version, size, etag = l.rstrip("\n").split("\t")
        p = key.split("/")
        run, f = p[-2].split("-", 1)[1], p[-1]
        if run not in up or f not in ("output", "report"):
            continue
        want = up[run]["output_etag" if f == "output" else "report_etag"]
        ok = etag == want
        bad += not ok
        cmp.append([run, f, c["cohort_id"], p[-2], etag, want, "yes" if ok else "no"])
w("law1-crosscheck.tsv", ["sample", "file", "e2_cohort", "variant", "engine_etag", "upstream_etag", "identical"], cmp)
failed = sum(x["exit"] != 0 for x in S)
print(f"u1_tables: {len(R)} rungs, {len(S)} sample runs ({failed} failed); Law-1 cross-check {len(cmp) - bad}/{len(cmp)} identical "
      f"over {len({c[2] for c in cmp})} E2 cohorts -> {T}/")
sys.exit(1 if failed or bad else 0)
