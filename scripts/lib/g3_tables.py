#!/usr/bin/env python3
"""Tables for a G3 campaign point (runs/g3-<exp>-<type>-n<N>.json; scripts/g3/campaign.body.sh),
from the record only: COHORT_DIR/{cohort.json, outputs.tsv, tables/tidy.tsv} and each member's
manifest.json and out/rank<r>/{c<C>.tsv, placement.tsv}.

  g3_tables.py COHORT_DIR   -> COHORT_DIR/tables/{batches,samples,consistency,point}.tsv

batches.tsv, per batch of the c<C> invocation: mode, place, inflight, threads, wall (the longest
rank's span from its first sample's start to its last sample's end), pairs, Mpairs/s, pairs per
rank (max, mean) and imbalance = max/mean, the planned imbalance from the weights, per-sample
classify rate (min, median, max), close seconds (median, max).
samples.tsv: one row per sample run (home and emitter roles).
consistency.tsv: per cohort run and output file, the variants (one per manifest line naming the
run) and their distinct ETags; consistent = one ETag and every variant present.
point.tsv: one row: the point's parameters, its phases (max over ranks; boot = launch to body
start; tail = end of the invocation to terminated), the batch walls by role, the within-run
spread of the repeated LPT batch, the measured cost, and derived columns (labelled derived_):
the cohort-only time and cost, T = boot + setup + manifest + fetch + load + LPT wall + tail, and
$/sample = N x price x T / cohort.
Exit 1 if any output is inconsistent or any manifest line has no output.
"""
import collections, csv, datetime as dt, json, os, statistics, sys

d = os.path.normpath(sys.argv[1])
T = os.path.join(d, "tables")
G = os.path.dirname(d)
coh = json.load(open(os.path.join(d, "cohort.json")))
rows = list(csv.DictReader(open(os.path.join(T, "tidy.tsv")), delimiter="\t"))
inv = sorted({r["invocation"] for r in rows if r["invocation"].startswith("c")})
assert len(inv) == 1, f"want one c<C> invocation, got {inv}"
inv = inv[0]
C = int(inv[1:])
members = sorted(coh["members"], key=lambda m: int(m["rank"]))
N = coh["nodes"]


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def w(name, head, body):
    with open(os.path.join(T, name), "w", newline="") as fh:
        x = csv.writer(fh, delimiter="\t", lineterminator="\n")
        x.writerow(head)
        x.writerows(body)


# The manifest (rank 0's copy; every rank builds the same) and the planned placement.
m0 = os.path.join(G, members[0]["run_id"], "out", "rank0")
man = [l.rstrip("\n").split("\t") for l in open(os.path.join(m0, f"{inv}.tsv")) if l.strip()]
plan = list(csv.DictReader(open(os.path.join(m0, "placement.tsv")), delimiter="\t"))
binfo = collections.OrderedDict()
for f in man:
    binfo.setdefault(f[0], {"mode": f[2], "inflight": f[1], "lines": []})["lines"].append(f[4])

S = collections.defaultdict(dict)
for r in rows:
    if r["invocation"] == inv and r["kind"] == "sample":
        S[(r["rank"], r["batch"], r["sample"])][r["metric"]] = r["value"]
runs = [(k, v) for k, v in S.items() if v.get("role") in ("home", "emitter")]

samples = []
for (rank, b, s), v in sorted(runs, key=lambda kv: (int(kv[0][1]), int(kv[0][0]), kv[0][2])):
    n, cl = int(v["sequences"]), float(v["classify_s"])
    samples.append([b, rank, v["role"], v["mode"], v.get("place", "-"), v.get("weight", "-"), v["inflight"], v["threads"], s, n,
                    f"{cl:.3f}", v["close_s"], v["wall_s"], f"{n / cl / 1e6:.3f}" if cl > 0 else "", v["status"]])
w("samples.tsv", ["batch", "rank", "role", "mode", "place", "weight", "inflight", "threads", "sample", "pairs", "classify_s",
                  "close_s", "wall_s", "Mpairs_per_s", "status"], samples)

batches, walls = [], {}
for b, bi in binfo.items():
    items = [v for (rank, bb, s), v in runs if bb == b]
    if not items:
        continue
    ranks = collections.defaultdict(list)
    for (rank, bb, s), v in runs:
        if bb == b:
            ranks[rank].append(v)
    span = max(max(float(v["start_s"]) + float(v["wall_s"]) for v in vs) - min(float(v["start_s"]) for v in vs)
               for vs in ranks.values())
    walls[b] = span
    pairs = sum(int(v["sequences"]) for v in items)
    rp = [sum(int(v["sequences"]) for v in ranks.get(str(k), [])) for k in range(N)]
    pw = collections.Counter()
    for p in plan:
        if p["batch"] == b and p["home"] != "all" and p["weight"] != "-":
            pw[int(p["home"])] += int(p["weight"])
    pimb = f"{max(pw.values()) / (sum(pw.values()) / N):.2f}" if pw and sum(pw.values()) else "-"
    mean = statistics.mean(rp)
    rates = [int(v["sequences"]) / float(v["classify_s"]) / 1e6 for v in items if float(v["classify_s"]) > 0]
    closes = [float(v["close_s"]) for v in items]
    place = items[0].get("place", "-")
    role = ("striped" if bi["mode"] == "striped" else
            "c1-home" if len(bi["lines"]) == 1 else f"cohort-{place}")
    batches.append([b, role, bi["mode"], place, bi["inflight"], items[0]["threads"], len(bi["lines"]), f"{span:.2f}", pairs,
                    f"{pairs / span / 1e6:.3f}", max(rp), f"{mean:.0f}", f"{max(rp) / mean:.2f}" if mean else "-", pimb,
                    f"{min(rates):.3f}", f"{statistics.median(rates):.3f}", f"{max(rates):.3f}",
                    f"{statistics.median(closes):.3f}", f"{max(closes):.3f}"])
w("batches.tsv", ["batch", "role", "mode", "place", "inflight", "threads", "samples", "wall_s", "pairs", "Mpairs_per_s",
                  "rank_pairs_max", "rank_pairs_mean", "imbalance", "planned_imbalance", "sample_Mpairs_per_s_min",
                  "sample_Mpairs_per_s_median", "sample_Mpairs_per_s_max", "close_s_median", "close_s_max"], batches)

# Consistency, from the launch host's listing of out/.
want = collections.Counter(f[4].split("-", 1)[1] for f in man)
groups = collections.defaultdict(list)
for l in open(os.path.join(d, "outputs.tsv")):
    if not l.strip():
        continue
    key, version, size, etag = l.rstrip("\n").split("\t")
    p = key.split("/")
    groups[(p[-2].split("-", 1)[1], p[-1])].append((p[-2], etag))
bad = 0
cons = []
for run in want:
    for f in ("output", "report"):
        vs = groups.get((run, f), [])
        ok = len({e for _, e in vs}) == 1 and len(vs) == want[run]
        bad += not ok
        cons.append([run, f, len(vs), want[run], len({e for _, e in vs}), "yes" if ok else "no"])
w("consistency.tsv", ["sample", "file", "variants", "want", "distinct_etags", "consistent"], cons)

# The point.
def ph(m, name):
    for p in m.get("phases", []):
        if p["phase"] == name:
            return float(p["seconds"]), ts(p["start"])
    return None, None


mans = [json.load(open(os.path.join(G, m["run_id"], "manifest.json"))) for m in members]
boot, setup, mphase, fetch, invs, tail = [], [], [], [], [], []
for m in mans:
    _, body0 = ph(m, "body")
    boot.append((body0 - ts(m["instance"]["launch_time"])).total_seconds())
    setup.append(ph(m, "setup")[0]); mphase.append(ph(m, "manifest")[0]); fetch.append(ph(m, "fetch")[0])
    s, st = ph(m, f"inv-{inv}")
    invs.append(s)
    term = m["instance"].get("terminated_at")
    tail.append((ts(term) - (st + dt.timedelta(seconds=s))).total_seconds() if term and st else float("nan"))
load = max(float(r["value"]) for r in rows if r["invocation"] == inv and r["kind"] == "phase" and r["metric"].startswith("shard-load-")
           and not r["metric"].endswith(".start_s"))
role_walls = collections.defaultdict(list)
for row in batches:
    role_walls[row[1]].append(float(row[7]))
lpt = role_walls.get("cohort-lpt", [])
spread = (abs(lpt[0] - lpt[1]) / statistics.mean(lpt[:2])) if len(lpt) >= 2 else float("nan")
price = float(mans[0].get("truffle_price_usd_per_hour") or "nan")
Tc = max(boot) + max(setup) + max(mphase) + max(fetch) + load + (lpt[0] if lpt else float("nan")) + max(tail)
med = lambda xs: f"{statistics.median(xs):.2f}" if xs else "-"
point = [coh["cohort_id"], mans[0]["task_id"], coh["instance_type"], N, C, f"{price:.4f}", f"{coh['cost_usd']:.4f}",
         max(int(m["billed_seconds"]) for m in mans), f"{max(boot):.0f}", f"{max(setup):.0f}", f"{max(mphase):.0f}",
         f"{max(fetch):.0f}", f"{load:.1f}", f"{lpt[0]:.2f}" if lpt else "-", f"{lpt[1]:.2f}" if len(lpt) > 1 else "-",
         f"{spread:.3f}", med(role_walls.get("cohort-mod", [])), med(role_walls.get("striped", [])),
         ",".join(f"{x:.2f}" for x in role_walls.get("striped", [])), med(role_walls.get("c1-home", [])),
         ",".join(f"{x:.2f}" for x in role_walls.get("c1-home", [])), f"{max(tail):.0f}",
         f"{Tc:.0f}", f"{N * price * Tc / 3600:.4f}", f"{N * price * Tc / 3600 / C:.5f}"]
w("point.tsv", ["cohort_id", "task", "type", "N", "cohort", "price_per_h", "cost_usd", "billed_s_max", "boot_s", "setup_s",
                "manifest_s", "fetch_s", "load_s", "lpt_wall_s", "lpt_repeat_wall_s", "lpt_spread", "mod_wall_s",
                "c1_striped_wall_s_median", "c1_striped_walls", "c1_home_wall_s_median", "c1_home_walls", "tail_s",
                "derived_cohort_T_s", "derived_cohort_cost_usd", "derived_usd_per_sample"], [point])
print(f"g3_tables: {inv}, {len(batches)} batches, {len(samples)} sample runs, consistency {len(cons) - bad}/{len(cons)}; "
      f"load {load:.1f} s, LPT wall {lpt[0] if lpt else float('nan'):.2f} s -> {T}/")
sys.exit(1 if bad else 0)
