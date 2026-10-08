#!/usr/bin/env python3
"""E1's per-batch and per-sample tables, from a cohort's tables/tidy.tsv (ak2-sample rows of the
c10 invocation, and the phases of every invocation).

  e1_batches.py COHORT_DIR  -> tables/batches.tsv, tables/samples.tsv, tables/invocations.tsv

batches.tsv, per c10 batch: wall (the longest rank's span from its first sample's start to its
last sample's end), pairs, pairs/s, the largest and mean pairs per rank (imbalance = max/mean),
per-sample classify rates (min, median, max) and close seconds (median, max).
samples.tsv: one row per sample run (batch, rank, role, sample, pairs, classify, close, wall,
rate). invocations.tsv: rank 0's phase seconds per invocation (load, rendezvous, connect,
classify, close, batch barriers).
"""
import collections, csv, os, statistics, sys

d = sys.argv[1]
rows = list(csv.DictReader(open(os.path.join(d, "tables", "tidy.tsv")), delimiter="\t"))
S = collections.defaultdict(dict)
for r in rows:
    if r["invocation"] == "c10" and r["kind"] == "sample":
        S[(r["rank"], r["batch"], r["sample"])][r["metric"]] = r["value"]


def w(name, head, body):
    with open(os.path.join(d, "tables", name), "w", newline="") as fh:
        x = csv.writer(fh, delimiter="\t", lineterminator="\n")
        x.writerow(head)
        x.writerows(body)


samples = []
for (rank, b, s), v in sorted(S.items(), key=lambda kv: (int(kv[0][1]), int(kv[0][0]), kv[0][2])):
    if v.get("role") not in ("home", "emitter"):
        continue
    n, cl = int(v["sequences"]), float(v["classify_s"])
    samples.append([b, rank, v["role"], v["mode"], v["s3client"], v["inflight"], v["threads"], s, n,
                    f"{cl:.3f}", v["close_s"], v["wall_s"], f"{n / cl / 1e6:.3f}" if cl > 0 else ""])
w("samples.tsv", ["batch", "rank", "role", "mode", "s3client", "inflight", "threads", "sample", "pairs",
                  "classify_s", "close_s", "wall_s", "Mpairs_per_s"], samples)

batches = []
for b in sorted({k[1] for k in S}, key=int):
    items = [v for k, v in S.items() if k[1] == b and v.get("role") in ("home", "emitter")]
    ranks = collections.defaultdict(list)
    for k, v in S.items():
        if k[1] == b and v.get("role") in ("home", "emitter"):
            ranks[k[0]].append(v)
    span = max(max(float(v["start_s"]) + float(v["wall_s"]) for v in vs) - min(float(v["start_s"]) for v in vs)
               for vs in ranks.values())
    pairs = sum(int(v["sequences"]) for v in items)
    rp = [sum(int(v["sequences"]) for v in vs) for vs in ranks.values()]
    rates = [int(v["sequences"]) / float(v["classify_s"]) / 1e6 for v in items if float(v["classify_s"]) > 0]
    closes = [float(v["close_s"]) for v in items]
    v0 = items[0]
    batches.append([b, v0["mode"], v0["s3client"], v0["inflight"], v0["threads"], f"{span:.2f}", pairs,
                    f"{pairs / span / 1e6:.3f}", max(rp), f"{statistics.mean(rp):.0f}", f"{max(rp) / statistics.mean(rp):.2f}",
                    f"{min(rates):.3f}", f"{statistics.median(rates):.3f}", f"{max(rates):.3f}",
                    f"{statistics.median(closes):.3f}", f"{max(closes):.3f}"])
w("batches.tsv", ["batch", "mode", "s3client", "inflight", "threads", "wall_s", "pairs", "Mpairs_per_s",
                  "rank_pairs_max", "rank_pairs_mean", "imbalance", "sample_Mpairs_per_s_min",
                  "sample_Mpairs_per_s_median", "sample_Mpairs_per_s_max", "close_s_median", "close_s_max"], batches)

inv = []
for i in sorted({r["invocation"] for r in rows}):
    ph = {r["metric"]: r["value"] for r in rows if r["invocation"] == i and r["rank"] == "0" and r["kind"] == "phase"
          and not r["metric"].endswith(".start_s")}
    for k in sorted(ph):
        if k.startswith(("shard-load", "rendezvous", "connect", "classify", "close", "batch-barrier", "barrier")):
            inv.append([i, k, ph[k]])
w("invocations.tsv", ["invocation", "phase", "seconds_rank0"], inv)
print(f"e1_batches: {len(batches)} batches, {len(samples)} sample runs -> {d}/tables/")
