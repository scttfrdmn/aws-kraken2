#!/usr/bin/env python3
"""Tables for the G3 probes (#25), from the record only (the run dir's pushed out/*.jsonl):

  probe_tables.py decomp RUN_DIR   -> tables/probe-decomp.tsv (mode seq), probe-decomp-conc.tsv
  probe_tables.py stage  RUN_DIR   -> tables/probe-staging.tsv
  probe_tables.py cont   COHORT_DIR -> tables/probe-contention.tsv, probe-contention-nodes.tsv

decomp: per tool and mode, the median seconds over repetitions and the per-sample GB/s of fq
written; identical = yes when both mates' output sha256 equals gzip -dc's. stage: one row per
step (the sweep's discard reads, the whole-object rget and s5cmd writes onto the tmpfs, the
time-limited aws s3 cp sample), with the ETag check's seconds after a whole write; ok = yes only
for a complete write whose ETag check passed. cont: per stage N, every reading node's GB/s over
its time-limited read (bytes of completed ranges / elapsed), and the minimum (the max-over-N
term), median, maximum and the aggregate (sum). Exits non-zero if a table cannot be made.
"""
import csv, glob, json, os, statistics, sys


def lines(p):
    return [json.loads(x) for x in open(p) if x.strip()]


def write(path, head, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(head)
        w.writerows(rows)
    print(f"probe_tables: {path} ({len(rows)} rows)")


mode, d = sys.argv[1], sys.argv[2]
if mode == "decomp":
    L = lines(os.path.join(d, "out", "decomp.jsonl"))
    ident = {}
    for x in L:
        if x["kind"] == "identity":
            ident.setdefault(x["tool"], []).append(bool(x["identical"]))
    T = {}
    for x in L:
        if x["kind"] == "time" and x["exit"] == 0:
            T.setdefault((x["tool"], x["mode"]), []).append(x["seconds"])
    if not T:
        sys.exit("probe_tables: no decomp timings")
    for m, name in (("seq", "probe-decomp.tsv"), ("conc", "probe-decomp-conc.tsv")):
        rows = []
        for (tool, mm), v in sorted(T.items()):
            if mm != m:
                continue
            ok = ident.get(tool, [])
            rows.append([tool, m, f"{statistics.median(v):.3f}", len(v), f"{min(v):.3f}", f"{max(v):.3f}",
                         "yes" if ok and all(ok) and len(ok) == 2 else "no"])
        write(os.path.join(d, "tables", name), ["tool", "mode", "seconds", "n", "min_s", "max_s", "identical"], rows)
elif mode == "stage":
    L = lines(os.path.join(d, "out", "stage.jsonl"))
    et = {x["label"]: x for x in L if x["kind"] == "etag"}
    rows = []
    for x in L:
        if x["kind"] != "done":
            continue
        lab = x["label"]
        if "gbps_cum" in x:  # k2probe rget
            sec, b, comp, g = x["elapsed_s"], x["bytes"], x["complete"], x["gbps_cum"]
        else:
            sec, b, comp, g = x["seconds"], x["bytes_allocated"], x["complete"], x["gbps"]
        tool = "rget" if lab.startswith(("sweep", "full-rget")) else lab.split("-")[1] if lab.startswith("full-") else "awscrt"
        e = et.get("etag-after-" + tool) if lab.startswith("full-") else None
        ok = "yes" if comp and e and e["ok"] else ("rate-only" if not lab.startswith("full-") else "no")
        rows.append([lab, tool, b, f"{sec:.2f}", f"{g:.3f}", "yes" if comp else "no", f"{e['seconds']:.2f}" if e else "-", ok])
    if not rows:
        sys.exit("probe_tables: no staging results")
    write(os.path.join(d, "tables", "probe-staging.tsv"),
          ["label", "tool", "bytes", "seconds", "gbps", "complete", "etag_s", "ok"], rows)
elif mode == "cont":
    c = json.load(open(os.path.join(d, "cohort.json")))
    G = os.path.dirname(d)
    per = {}
    for m in [m for m in c["members"] if m.get("run_id")]:
        for f in glob.glob(os.path.join(G, m["run_id"], "out", "cont-*.jsonl")):
            for x in lines(f):
                if x["kind"] == "done":
                    n = int(x["label"].split("-")[0][1:])
                    per.setdefault(n, []).append((x["label"], x["bytes"], x["elapsed_s"], x["gbps_cum"], x["retries"],
                                                  x.get("error", "")))
    if not per:
        sys.exit("probe_tables: no contention results")
    rows, nodes = [], []
    for n in sorted(per):
        v = per[n]
        g = [x[3] for x in v]
        rows.append([n, len(v), f"{min(g):.3f}", f"{statistics.median(g):.3f}", f"{max(g):.3f}", f"{sum(g):.3f}",
                     sum(x[4] for x in v), sum(1 for x in v if x[5]), "50 (c8gn.4xlarge baseline)"])
        nodes += [[n] + list(x[:2]) + [f"{x[2]:.2f}", f"{x[3]:.3f}", x[4], x[5] or "-"] for x in sorted(v)]
        if len(v) != n:
            print(f"probe_tables: stage N={n} has {len(v)} reading nodes", file=sys.stderr)
    write(os.path.join(d, "tables", "probe-contention.tsv"),
          ["N", "nodes_reported", "node_min_gbps", "node_median_gbps", "node_max_gbps", "aggregate_gbps", "retries",
           "nodes_with_error", "nic_gbps"], rows)
    write(os.path.join(d, "tables", "probe-contention-nodes.tsv"),
          ["N", "label", "bytes", "elapsed_s", "gbps", "retries", "error"], nodes)
    if any(int(r[1]) != int(r[0]) for r in rows):
        sys.exit(1)
else:
    sys.exit("usage: probe_tables.py decomp|stage|cont DIR")
