#!/usr/bin/env python3
"""Tables for the G3 probes (#25), from the record only (the run dir's pushed out/*.jsonl):

  probe_tables.py decomp RUN_DIR   -> tables/probe-decomp.tsv (mode seq), probe-decomp-conc.tsv
  probe_tables.py stage  RUN_DIR   -> tables/probe-staging.tsv
  probe_tables.py cont   COHORT_DIR -> tables/probe-contention.tsv, probe-contention-nodes.tsv
  probe_tables.py awscp  RUN_DIR   -> tables/probe-awscp.tsv, probe-awscp-progress.tsv (the classic aws s3 cp rate)

decomp: per tool and mode, the median seconds over repetitions and the per-sample GB/s of fq
written; identical = yes when both mates' output sha256 equals gzip -dc's. stage: one row per
step (the sweep's discard reads, the whole-object rget and s5cmd writes onto the tmpfs, the
time-limited aws s3 cp sample), with the ETag check's seconds after a whole write; ok = yes only
for a complete write whose ETag check passed. cont: per stage N, every reading node's GB/s over
its time-limited read (bytes of completed ranges / elapsed), the spread of the nodes' start times, and the minimum (the max-over-N
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
                                                  x.get("error", ""), x["unix_s"] - x["elapsed_s"]))
    if not per:
        sys.exit("probe_tables: no contention results")
    rows, nodes = [], []
    for n in sorted(per):
        v = per[n]
        g = [x[3] for x in v]
        rows.append([n, len(v), f"{min(g):.3f}", f"{statistics.median(g):.3f}", f"{max(g):.3f}", f"{sum(g):.3f}",
                     sum(x[4] for x in v), sum(1 for x in v if x[5]), "50 (c8gn.4xlarge baseline)",
                     f"{max(x[6] for x in v) - min(x[6] for x in v):.2f}"])
        nodes += [[n] + list(x[:2]) + [f"{x[2]:.2f}", f"{x[3]:.3f}", x[4], x[5] or "-", f"{x[6]:.3f}"] for x in sorted(v)]
        if len(v) != n:
            print(f"probe_tables: stage N={n} has {len(v)} reading nodes", file=sys.stderr)
    write(os.path.join(d, "tables", "probe-contention.tsv"),
          ["N", "nodes_reported", "node_min_gbps", "node_median_gbps", "node_max_gbps", "aggregate_gbps", "retries",
           "nodes_with_error", "nic_gbps", "start_spread_s"], rows)
    write(os.path.join(d, "tables", "probe-contention-nodes.tsv"),
          ["N", "label", "bytes", "elapsed_s", "gbps", "retries", "error", "start_unix_s"], nodes)
    if any(int(r[1]) != int(r[0]) for r in rows):
        sys.exit(1)
elif mode == "awscp":
    # The classic aws s3 cp rate (probe-awscp.body.sh): one summary row, and the 10 s progress series.
    L = lines(os.path.join(d, "out", "awscp.jsonl"))
    cl = next((x for x in L if x["kind"] == "client"), {})
    cf = next((x for x in L if x["kind"] == "config"), {})
    dn = [x for x in L if x["kind"] == "done"]
    pr = [x for x in L if x["kind"] == "progress"]
    if not dn or not pr:
        sys.exit("probe_tables: no awscp done line or no progress lines")
    x = dn[-1]
    fmt = lambda v, nd=3: "-" if v is None else (f"{v:.{nd}f}" if isinstance(v, float) else str(v))
    ttl_s = 360 * 60   # S0-T1 and S0-Tv's TTL (ladder.levers.tsv ttl_min_c1), which this rate is to size
    est = x.get("est_object_s_steady") or x.get("est_object_s")
    write(os.path.join(d, "tables", "probe-awscp.tsv"),
          ["instance_type", "client", "resolved", "cli_version", "signing", "stopped_by", "s", "bytes", "bytes_basis", "gbps",
           "gb_per_s", "steady_gbps", "object_bytes", "est_object_s", "est_object_s_steady", "s0_ttl_s", "est_over_s0_ttl"],
          [[cf.get("instance_type", "-"), cl.get("client", "-"), cl.get("resolved", "-"), cl.get("cli_version", "-"),
            cf.get("signing", "-"), x["stopped_by"], fmt(x["s"]), x["bytes"], pr[-1].get("bytes_basis", "-"), fmt(x.get("gbps")),
            fmt(x.get("gb_per_s")), fmt(x.get("steady_gbps")), x["object_bytes"], fmt(x.get("est_object_s")),
            fmt(x.get("est_object_s_steady")), ttl_s, "-" if not est else f"{est / ttl_s:.3f}"]])
    write(os.path.join(d, "tables", "probe-awscp-progress.tsv"),
          ["s", "bytes", "bytes_basis", "allocated_bytes", "gbps", "interval_gbps", "gb_per_s"],
          [[fmt(p["s"]), p["bytes"], p["bytes_basis"], p["allocated_bytes"], fmt(p.get("gbps")), fmt(p.get("interval_gbps")),
            fmt(p.get("gb_per_s"))] for p in pr])
    if x["stopped_by"] not in ("time", "bytes", "complete"):
        sys.exit(1)
else:
    sys.exit("usage: probe_tables.py decomp|stage|cont|awscp DIR")
