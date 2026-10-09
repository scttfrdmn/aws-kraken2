#!/usr/bin/env python3
"""Engine memory per campaign point (#25), from the pushed engine stderr's ak2-engine mem lines.

  g3_memory.py [SINCE]   -> results/g3/campaign/memory.tsv

Per cohort and rank: the instance type, N, samples in flight, the peak VmHWM, the shard's size
(hash.k2d / N), the working memory above it (peak - shard), and the lowest MemAvailable seen.
Members killed before pushing their stderr are read from the streamed lines in the cohort's
rank-<k>.run.log instead. The working memory per sample in flight is what mkspec's memory rule
needs (the rule assumed 2 GB per sample in flight; E3 c8g.12xlarge at 3 in flight was killed).
"""
import csv, glob, json, os, re, sys

SINCE = sys.argv[1] if len(sys.argv) > 1 else "2026-10-08T04:00:00Z"
HASH = 1189091671800
G = "results/g3"
rows = []
for cj in sorted(glob.glob(os.path.join(G, "2026*", "cohort.json"))):
    c = json.load(open(cj))
    if str(c.get("start", "")).replace("+00:00", "Z") < SINCE or not str(c.get("spec", "")).startswith("runs/g3-e"):
        continue
    d = os.path.dirname(cj)
    N = int(c["nodes"])
    body = json.load(open(os.path.join(G, c["members"][0]["run_id"], "spec.json")))["command"][2] if os.path.exists(
        os.path.join(G, c["members"][0]["run_id"], "spec.json")) else ""
    m = re.search(r"INFLIGHT=([a-z0-9]+)", body)
    inflight = m.group(1) if m else "-"
    for mem in c["members"]:
        k = int(mem["rank"])
        lines = []
        for f in glob.glob(os.path.join(G, mem["run_id"], "out", f"rank{k}", "eng-*.stderr")):
            lines += [l for l in open(f, errors="replace") if l.startswith("ak2-engine\tmem\t")]
        src = "stderr"
        if not lines:
            rl = os.path.join(d, f"rank-{k}.run.log")
            if os.path.exists(rl):
                lines = [l[l.index("ak2-engine\tmem\t"):] for l in open(rl, errors="replace") if "ak2-engine\tmem\t" in l]
                src = "streamed run log"
        if not lines:
            continue
        kv = [dict(zip(l.rstrip("\n").split("\t")[2::2], l.rstrip("\n").split("\t")[3::2])) for l in lines]
        hwm = max(int(x["hwm_kib"]) for x in kv) * 1024
        avail = min(int(x["avail_kib"]) for x in kv) * 1024
        shard = HASH / N
        rows.append([os.path.basename(d), c.get("instance_type"), N, k, inflight, mem.get("rc", ""), f"{hwm / 2**30:.1f}",
                     f"{shard / 2**30:.1f}", f"{(hwm - shard) / 2**30:.1f}", f"{avail / 2**30:.1f}", len(kv), src])
os.makedirs(os.path.join(G, "campaign"), exist_ok=True)
with open(os.path.join(G, "campaign", "memory.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["cohort", "type", "N", "rank", "inflight_param", "member_rc", "hwm_gib", "shard_gib", "working_gib",
                "min_avail_gib", "samples", "source"])
    w.writerows(rows)
print(f"g3_memory: {len(rows)} ranks -> {G}/campaign/memory.tsv")
