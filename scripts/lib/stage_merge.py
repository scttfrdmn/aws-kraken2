#!/usr/bin/env python3
"""Merge a stage-cohort cohort's per-member staged.tsv files into the cohort record.

  stage_merge.py COHORT_DIR [PROJECT] [FROM] [COUNT]

Reads COHORT_DIR/cohort.json (its members' run ids), each member's
results/<gate>/<run_id>/out/staged.tsv, and results/cohort/<PROJECT>/{runs,staged}.tsv. Writes
results/cohort/<PROJECT>/staged.tsv: every row already there plus every new one, one row per
object version (run, mate, bytes, md5, sha256, key, version_id), in cohort order (rank, mate,
time). Checks that every rank FROM..COUNT has both mates, with bytes and md5 as runs.tsv records
them. Writes COHORT_DIR/tables/staged-check.tsv (rank, run, mate, ok, why). Exit 1 if any check
fails (the merged record is still written, so a rerun only adds what is missing).
"""
import csv, json, os, sys

d = os.path.normpath(sys.argv[1])
project = sys.argv[2] if len(sys.argv) > 2 else "PRJNA398089"
lo = int(sys.argv[3]) if len(sys.argv) > 3 else 11
hi = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
rec = os.path.join("results", "cohort", project)
coh = json.load(open(os.path.join(d, "cohort.json")))
head = ["run", "mate", "bytes", "md5", "sha256", "key", "version_id", "at"]
runs = list(csv.DictReader(open(os.path.join(rec, "runs.tsv")), delimiter="\t"))
rank_of = {r["run"]: int(r["rank"]) for r in runs}

rows, seen = [], set()


def add(path):
    n = 0
    for r in csv.DictReader(open(path), delimiter="\t"):
        k = tuple(r[h] for h in head[:7])
        if k not in seen:
            seen.add(k)
            rows.append(r)
            n += 1
    return n


add(os.path.join(rec, "staged.tsv"))
new = 0
for m in coh["members"]:
    p = os.path.join(os.path.dirname(d), m["run_id"], "out", "staged.tsv")
    if os.path.exists(p):
        new += add(p)
    else:
        print(f"stage_merge: member {m['run_id']} has no out/staged.tsv", file=sys.stderr)
rows.sort(key=lambda r: (rank_of.get(r["run"], 10**9), int(r["mate"]), r["at"]))
with open(os.path.join(rec, "staged.tsv"), "w", newline="") as fh:
    w = csv.DictWriter(fh, head, delimiter="\t", lineterminator="\n")
    w.writeheader()
    w.writerows(rows)

have = {}
for r in rows:
    have.setdefault((r["run"], r["mate"]), []).append(r)
bad = 0
os.makedirs(os.path.join(d, "tables"), exist_ok=True)
with open(os.path.join(d, "tables", "staged-check.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["rank", "run", "mate", "ok", "why"])
    for r in runs:
        k = int(r["rank"])
        if not lo <= k <= hi:
            continue
        for m in ("1", "2"):
            got = have.get((r["run"], m), [])
            ok = any(g["bytes"] == r[f"bytes_{m}"] and g["md5"] == r[f"md5_{m}"] for g in got)
            why = "" if ok else ("not staged" if not got else "bytes or md5 differ from runs.tsv")
            bad += not ok
            w.writerow([k, r["run"], m, "yes" if ok else "no", why])
print(f"stage_merge: {len(rows)} rows in {rec}/staged.tsv ({new} new); ranks {lo}..{hi}: {bad} files missing or wrong")
sys.exit(1 if bad else 0)
