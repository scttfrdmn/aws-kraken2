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
point.tsv: one row: the point's parameters (inflight, threads), its phases (max over ranks; boot =
launch to body start), the batch walls by role, the within-run spread of the repeated LPT batch,
whether the placement + order lever (j mod N vs LPT) is resolved (its gain above 2 x the spread),
and T defined three ways (see the comment at "T, defined"): derived (a sum of per-term maxima),
observed (first launch to the last rank's end of batch 0), and with the body and harness tails;
$/sample derived as N x price x T / cohort (engine T, and with the harness tail), and measured as
the summed member cost / cohort (the whole run, every batch).
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
# Per rank: launch, body start, the invocation's start and end, the body's end, terminated, and
# the end of its batch-0 (LPT) samples (process-relative start_s + wall_s from the invocation start).
boot, setup, mphase, fetch, body_tail, harness_tail, b0_end, launches = [], [], [], [], [], [], [], []
for k, m in enumerate(mans):
    launch = ts(m["instance"]["launch_time"])
    launches.append(launch)
    _, body0 = ph(m, "body")
    boot.append((body0 - launch).total_seconds())
    setup.append(ph(m, "setup")[0]); mphase.append(ph(m, "manifest")[0]); fetch.append(ph(m, "fetch")[0])
    s_inv, st = ph(m, f"inv-{inv}")
    inv_end = st + dt.timedelta(seconds=s_inv)
    # The body's end: the preamble's "end" phase line in the member's run log (not in manifest phases).
    end0 = None
    for l in open(os.path.join(G, members[k]["run_id"], "log", "run.log"), errors="replace"):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 4 and f[0].endswith("ak2-phase") and f[3] == "end":
            end0 = ts(f[1])
    end0 = end0 or inv_end
    # The engine process's own end: its ak2-timing "total" (from process start); the body tail is
    # what the body did after it (request accounting, the stderr push).
    tot = [float(r["value"]) for r in rows if r["invocation"] == inv and r["kind"] == "phase" and r["metric"] == "total"
           and r["rank"] == str(k)]
    eng_end = st + dt.timedelta(seconds=tot[-1]) if tot else inv_end
    body_tail.append((end0 - eng_end).total_seconds())
    term = m["instance"].get("terminated_at")
    harness_tail.append((ts(term) - end0).total_seconds() if term else float("nan"))
    ends = [float(v["start_s"]) + float(v["wall_s"]) for (rank, bb, s_), v in runs if bb == "0" and rank == str(k)]
    if ends:
        b0_end.append(st + dt.timedelta(seconds=max(ends)))
load = max(float(r["value"]) for r in rows if r["invocation"] == inv and r["kind"] == "phase" and r["metric"].startswith("shard-load-")
           and not r["metric"].endswith(".start_s"))
rdv = max((float(r["value"]) for r in rows if r["invocation"] == inv and r["kind"] == "phase" and r["metric"] == "rendezvous"),
          default=float("nan"))
role_walls = collections.defaultdict(list)
for row in batches:
    role_walls[row[1]].append(float(row[7]))
lpt = role_walls.get("cohort-lpt", [])
spread = (abs(lpt[0] - lpt[1]) / statistics.mean(lpt[:2])) if len(lpt) >= 2 else float("nan")
price = float(mans[0].get("truffle_price_usd_per_hour") or "nan")
member_cost = sum(float(m.get("cost_usd") or 0) for m in mans)
b0 = [b for b in batches if b[0] == "0"][0]
# T, defined (docs/cohort.md, "The G3 campaign"):
#   derived  = max boot + max setup + max manifest + max fetch + max load + LPT wall (each term its
#              own maximum over ranks, so the sum is not any one rank's path);
#   observed = first launch -> the last rank's end of batch 0 (the cohort's critical path, measured);
#   skew + rendezvous = observed - derived (ranks reaching the rendezvous at different times, the
#              rendezvous itself, and the batch's start skew);
#   tails: body tail = the engine process's end -> the body's end (requests, the stderr push); harness
#              tail = the body's end -> terminated (the harness's finish and EC2's termination).
derived = max(boot) + max(setup) + max(mphase) + max(fetch) + load + (lpt[0] if lpt else float("nan"))
observed = (max(b0_end) - min(launches)).total_seconds() if b0_end else float("nan")
T_eng = observed + max(body_tail)  # the cohort's result is out when batch 0 ends; the body tail is still the run's
T_all = T_eng + max(harness_tail)
med = lambda xs: f"{statistics.median(xs):.2f}" if xs else "-"
lever_res = "-"
mod = role_walls.get("cohort-mod", [])
if mod and lpt:
    gain = mod[0] / lpt[0] - 1
    lever_res = "resolved" if gain > 2 * spread else "unresolved"
ht_sorted = sorted(harness_tail)
# #44: the engine is pre-fix unless the run's commit descends from the clean-room HitCounts (904c2a5).
import subprocess
_rc = subprocess.run(["git", "merge-base", "--is-ancestor", "904c2a5", coh.get("commit", "")], capture_output=True).returncode
pre_fix = "no" if _rc == 0 else ("yes" if _rc == 1 else "unknown")
point = [coh["cohort_id"], mans[0]["task_id"], pre_fix, coh["instance_type"], N, C, b0[4], b0[5], f"{price:.4f}", f"{member_cost:.4f}",
         max(int(m["billed_seconds"]) for m in mans), f"{max(boot):.0f}", f"{max(setup):.0f}", f"{max(mphase):.0f}",
         f"{max(fetch):.0f}", f"{load:.1f}", f"{rdv:.1f}", f"{lpt[0]:.2f}" if lpt else "-", f"{lpt[1]:.2f}" if len(lpt) > 1 else "-",
         f"{spread:.3f}", med(mod), lever_res, med(role_walls.get("striped", [])),
         ",".join(f"{x:.2f}" for x in role_walls.get("striped", [])), med(role_walls.get("c1-home", [])),
         ",".join(f"{x:.2f}" for x in role_walls.get("c1-home", [])),
         f"{derived:.0f}", f"{observed:.0f}", f"{observed - derived:.0f}", f"{max(body_tail):.0f}",
         f"{max(harness_tail):.0f}", f"{statistics.median(harness_tail):.0f}", ",".join(f"{x:.0f}" for x in ht_sorted[-3:]),
         f"{T_eng:.0f}", f"{T_all:.0f}",
         f"{N * price * T_eng / 3600 / C:.5f}", f"{N * price * T_all / 3600 / C:.5f}", f"{member_cost / C:.5f}"]
w("point.tsv", ["cohort_id", "task", "engine_pre_fix", "type", "N", "cohort", "inflight", "threads", "price_per_h", "cost_usd_members", "billed_s_max",
                "boot_s", "setup_s", "manifest_s", "fetch_s", "load_s", "rendezvous_s_max", "lpt_wall_s", "lpt_repeat_wall_s",
                "lpt_spread", "mod_wall_s", "placement_order_lever", "c1_striped_wall_s_median", "c1_striped_walls",
                "c1_home_wall_s_median", "c1_home_walls", "derived_T_s", "observed_T_s", "skew_rendezvous_s", "body_tail_s",
                "harness_tail_s_max", "harness_tail_s_median", "harness_tail_s_top3", "T_engine_s", "T_with_harness_s",
                "derived_usd_per_sample_engine", "derived_usd_per_sample_with_harness", "measured_usd_per_sample_whole_run"], [point])
print(f"g3_tables: {inv}, {len(batches)} batches, {len(samples)} sample runs, consistency {len(cons) - bad}/{len(cons)}; "
      f"load {load:.1f} s, LPT wall {lpt[0] if lpt else float('nan'):.2f} s, observed T {observed:.0f} s (derived {derived:.0f}) -> {T}/")
sys.exit(1 if bad else 0)
