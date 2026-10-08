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
P = [x for x in L if x["kind"] == "prep"]
prep_s = [x["seconds"] for x in P]
FQ_LABEL = (f"fq, pre-decompressed (pigz -dc -p 16 onto tmpfs before the sample's rungs, not timed in them; "
            f"{len(P)} preparations, median {statistics.median(prep_s):.1f} s, total {sum(prep_s):.0f} s; prep.tsv)") if P else "fq, pre-decompressed"


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
                 med([x["classify_s"] for x in ss if x["classify_s"] is not None]), med([x["wall_s"] for x in ss]), "measured",
                 FQ_LABEL if r["input"] == "fq" else "gz as staged"])
cells = collections.defaultdict(list)
for x in S:
    if x["rung"].startswith("A-c1-"):
        cells[(x["input"], x["threads"])].append(x["wall_s"])
for (inp, t), ws in sorted(cells.items()):
    pairs = S[0]["pairs"] if S else 0
    rows.append([f"A-c1-{inp}-t{t} (n={len(ws)})", inp, t, 1, 1, len(ws), 0, f"{statistics.median(ws):.2f}", pairs,
                 f"{pairs / statistics.median(ws) / 1e6:.3f}", "-", f"{min(ws):.3f}-{max(ws):.3f}", "measured",
                 FQ_LABEL if inp == "fq" else "gz as staged"])
# Modelled, flagged: upstream at cohort 100, gz, one process at a time (not run; about 50 min),
# from the best measured one-process gz rate (pairs / wall over every A and B one-process gz run).
gz1 = collections.defaultdict(lambda: [0, 0.0])
for x in S:
    if x["input"] == "gz" and (x["rung"].startswith("A-c1-gz") or x["rung"] == "B-c10-gz-t48"):
        gz1[x["threads"]][0] += x["pairs"]
        gz1[x["threads"]][1] += x["wall_s"]
c100 = [x for x in S if x["rung"] == "C-c100-fq-t96"]
if gz1 and c100:
    bt, (bp, bw) = max(gz1.items(), key=lambda kv: kv[1][0] / kv[1][1])
    rate = bp / bw
    cp = sum(x["pairs"] for x in c100)
    rows.append([f"C-c100-gz-t{bt}-one-process MODELLED", "gz", bt, 1, len(c100), 0, 0, f"{cp / rate:.2f}", cp, f"{rate / 1e6:.3f}",
                 "-", "-", f"modelled: the best measured one-process gz rate ({rate / 1e6:.3f} Mpairs/s at T={bt}, A and B runs) "
                 f"applied to cohort 100's pairs; not run", "gz as staged"])
w("rungs.tsv", ["rung", "input", "threads", "procs", "cohort", "samples", "failed", "pass_wall_s", "pairs", "Mpairs_per_s",
                "classify_s_median", "wall_s_median_or_range", "basis", "input_label"], rows)
w("prep.tsv", ["sample", "tool", "seconds", "fq_bytes"], [[x["sample"], x["tool"], f"{x['seconds']:.2f}", x["fq_bytes"]] for x in P])
w("drift.tsv", ["rung", "start", "wall_s", "classify_s"],
  [[x["rung"], f"{x['start']:.0f}", f"{x['wall_s']:.3f}", x["classify_s"]] for x in S if x["rung"].startswith("ref")])

# Law 1 on the real cohort: every sample of the ETag rung, against every engine cohort of the
# campaign (E2, E3, E4 at cohort 100): each sample's output and report must be present in each
# cohort's outputs.tsv, every variant there carrying upstream's ETag. A sample without an
# upstream ETag, or a cohort missing a sample's file, is a failure, not a skip.
up = {x["sample"]: x for x in S if x["rung"] == "C-c100-fq-t96"}
cmp, bad, missing = [], 0, []
for s_, x in up.items():
    if x["exit"] != 0 or x["output_etag"] in ("-", "") or x["report_etag"] in ("-", ""):
        missing.append(f"U1 has no ETag for {s_}")
cohorts = 0
for cj in sorted(glob.glob(os.path.join(os.path.dirname(d), "*", "cohort.json"))):
    c = json.load(open(cj))
    if not any(str(c.get("spec", "")).startswith(f"runs/g3-{e}-") for e in ("e2", "e3", "e4")):
        continue
    o = os.path.join(os.path.dirname(cj), "outputs.tsv")
    if not os.path.exists(os.path.join(os.path.dirname(cj), "tables", "point.tsv")) or not os.path.exists(o):
        continue  # a failed or interrupted attempt: no point, nothing to compare
    cohorts += 1
    seen = set()
    for l in open(o):
        if not l.strip():
            continue
        key, version, size, etag = l.rstrip("\n").split("\t")
        p = key.split("/")
        run, f = p[-2].split("-", 1)[1], p[-1]
        if f not in ("output", "report"):
            continue
        if run not in up:
            missing.append(f"{c['cohort_id']} has {run}, which U1's ETag rung has not")
            continue
        seen.add((run, f))
        want = up[run]["output_etag" if f == "output" else "report_etag"]
        ok = etag == want
        bad += not ok
        cmp.append([run, f, c["cohort_id"], p[-2], etag, want, "yes" if ok else "no"])
    for run in up:
        for f in ("output", "report"):
            if (run, f) not in seen:
                missing.append(f"{c['cohort_id']} lacks {run}/{f}")
w("law1-crosscheck.tsv", ["sample", "file", "engine_cohort", "variant", "engine_etag", "upstream_etag", "identical"], cmp)
w("law1-coverage.tsv", ["problem"], [[m] for m in missing])
failed = sum(x["exit"] != 0 for x in S)
print(f"u1_tables: {len(R)} rungs, {len(S)} sample runs ({failed} failed), {len(P)} fq preparations; Law-1 cross-check "
      f"{len(cmp) - bad}/{len(cmp)} identical over {cohorts} engine cohorts, {len(missing)} coverage problems -> {T}/")
if not cmp:
    print("u1_tables: no comparisons were made (the cross-check needs at least one engine cohort)", file=sys.stderr)
sys.exit(1 if failed or bad or missing or not cmp else 0)
