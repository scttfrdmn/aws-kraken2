#!/usr/bin/env python3
"""H-main per-axis bests and Pareto sets (#25): ours against upstream at its best, per cohort
size and regime, from the record only.

  g3_frontier.py   -> results/g3/campaign/frontier.{tsv,md}, pareto.tsv, upstream_sp_sweep.tsv

Inputs: results/g3/campaign/points.tsv (E2-E4, from g3_campaign.py), the E1 cohort (cohort 10),
U1 (results/g3/*/out/u1.jsonl with tables/rungs.tsv, prep.tsv), U2 (out/g2-u2/summary.tsv),
each run's manifest (phases, launch time, truffle price), results/cohort/PRJNA398089/runs.tsv.

Definitions (generated into frontier.md):
  - Every engine point here is pre-fix (its engine predates the #44 fix, 904c2a5) until the
    points are regenerated; the engine_pre_fix column says so per point (unknown where the commit
    cannot be placed).
  - Regimes. resident: the table is already in memory (ours: the in-run batch walls after the
    load; upstream: U1's passes on a tmpfs-resident table, U2's warm rung). from-scratch: from the
    first instance launch to the result, on the critical path: ours at cohort 1 and 100 is the
    observed path (first launch to the last rank's start of the cohort's batch, so boot, setup,
    fetch, load, rendezvous and skew are all in it) plus the batch and the body tail; E1's cohort
    10 is the same rule from its records; upstream is boot + setup + the table's staging + the
    input fetch + the pass.
  - Upstream's fq passes have their fq preparation added back (U1's pre-decompression, per sample
    its fastest preparation, prep.tsv). Input sha256 verification is inside both sides' input
    fetch phases. The table's ETag check (U1: 31.4 s, U2: 150.3 s, from each run's log) was inside
    upstream's recorded fetch-db phase; ours computes none, so it is taken out of upstream's staging
    here (the basis column gives the seconds). Upstream's input fetch is the node's own input bytes
    (runs.tsv) at U1's measured input rate (107.8 GB in 35 s), not the whole 100-sample fetch.
  - Phase split, per row (frontier.tsv ph_* columns; for derived upstream points, the critical
    node's): fixed (boot, setup; ours also manifest, rendezvous, skew and the body tail), table
    staging, input fetch, decompression/preparation (upstream's fq path; ours and upstream's gz
    path decompress inside classify), classify. Each per-axis best gives each phase's ratio.
  - Staging break-even, per from-scratch cell: the upstream staging rate (GB/s) at which the ratio
    would be 5x (the kill line) and 1x, the rest of that upstream point held fixed.
  - Time: measured wall seconds. $/sample: derived (on-demand price x nodes x that wall /
    cohort), on both sides. Where a run's billed cost covers exactly the cohort's work it is not
    separable here; billed/derived is shown where a whole run's bill is known (ours at cohort 100,
    from scratch: the bill covers every batch of the run, so the ratio exceeds 1).
  - Per-axis bests: the minimum time and, separately, the minimum $/sample on each side. They are
    not a frontier; the Pareto sets (non-dominated in time and $/sample, per side) are pareto.tsv.
  - Law 5 attribution of each ratio (upstream / ours; > 1: ours is better), from the two best
    points' fleet vCPUs V, price per vCPU-hour p and per-vCPU rate e = pairs / (V x wall):
    time ratio = (V_ours / V_up) x (e_ours / e_up); $ ratio = (p_up / p_ours) x (e_ours / e_up).
    From scratch, e includes staging; the staging seconds and bandwidth are shown beside it.
  - Upstream at its best (Scott's ruling 1, #25; an addition to the registration): the best of single-node
    upstream (U1, U2 as measured) and upstream sample-parallel, N independent upstream nodes each holding
    the table and running its share of the cohort. The sample-parallel arm is derived from the
    single-node measurements, not measured: per node, the fixed costs (boot, setup, the table's staging
    and, on U1, the input fetch) plus the per-sample walls of a measured rung (U1: each rung's per-sample
    walls at its P x T, fq with its preparation; U2: the SRR5935740 warm wall per pair, the first sample
    on each node at the cold wall), scheduled by LPT over N x P slots, for N = 1..cohort; the N that
    minimises time and the N that minimises $/sample are picked separately per regime and node type
    (the whole sweep is upstream_sp_sweep.tsv). From scratch, every node stages the table itself: in
    parallel (once in time) and paid N times in $. Biases against upstream: U1's gz P x T rungs'
    per-sample walls were measured at the rung's full concurrency P, so a lightly loaded node is
    modelled slower than it would run (the fq rungs are P = 1 and carry no such bias). Biases for
    upstream: under the "measured" staging variant, N parallel table stagings run at the single-node
    rate with no S3 contention (beyond the about 51 GB/s aggregate our own fleets measured, it is
    unmeasured), and the critical node's fixed costs are the single node's, not the maximum over N
    nodes' boots and stagings. Upstream variants, each labelled: staging as measured, at probe (a)'s
    best-practice rate, and at that rate capped by probe (b)'s contention curve (the slowest node at
    N, the max-over-N term); decompression with pigz as measured, with each probe (c) tool scaled by
    its time relative to pigz on the same node (only tools whose output is byte-identical), and
    decompression overlapped with the previous sample's classify. The width x per-vCPU decomposition
    of a sample-parallel point is not a lever attribution: its V is N x the node's vCPUs at the
    floor, N set by the smallest-N tie-break. Not extended to cohort 1000 (no measured walls beyond
    cohort 100).
  - Registered reference points (#25 H-main): ~20x lower $/sample at cohort >= 100; ~6x (Tier A)
    to 20x faster for a single sample. Kill condition: under 5x on both axes at every cohort size,
    evaluated per regime (Scott's ruling 2, #25; an addition to the registration) on the measured
    cohort sizes (1, 10, 100), against the best of single-node and sample-parallel upstream.
  - Cohort 1000: ours is a placeholder only (Scott's decision: the engine side uses real
    samples), extrapolated from cohort 100 by the pairs ratio and never a best. Upstream's
    cohort-1000 model is infeasible as specified: about 1.4 TB of fq input plus RODA's 1.19 TB
    table on a 1536 GiB tmpfs node; it is shown, flagged, for completeness.
"""
import csv, datetime as dt, glob, heapq, json, os, re, statistics, subprocess

G = "results/g3"
OUT = os.path.join(G, "campaign")
HASH_GB = 1189.091671800


def tsv(p):
    return list(csv.DictReader(open(p), delimiter="\t"))


def ts(x):
    return dt.datetime.fromisoformat(x.replace("Z", "+00:00"))


def phases(m):
    return {p["phase"]: p for p in m.get("phases", [])}


def boot_of(m):
    return (ts(phases(m)["body"]["start"]) - ts(m["instance"]["launch_time"])).total_seconds()


def prefix(commit):
    if not commit:
        return "unknown"
    rc = subprocess.run(["git", "merge-base", "--is-ancestor", "904c2a5", commit], capture_output=True).returncode
    return "yes" if rc == 1 else ("no" if rc == 0 else "unknown")


runs = tsv("results/cohort/PRJNA398089/runs.tsv")
order = [r["run"] for r in runs]
pairs = lambda c: sum(int(r["read_count"]) for r in runs if int(r["rank"]) <= c)
R1000 = pairs(1000) / pairs(100)
rows = []


def add(c, regime, side, point, t, nodes, vcpus, price_h, pre, kind, basis, stage_s="-", stage_gbs="-", billed="-",
        ph=None, extra=None):
    V = nodes * vcpus
    rows.append({"ph": ph, "extra": extra or {}, "cohort": c, "regime": regime, "side": side, "point": point, "time_s": t,
                 "usd_per_sample": nodes * price_h * t / 3600 / c, "fleet_vcpus": V,
                 "usd_per_vcpu_h": price_h / vcpus, "mpairs_per_s_per_vcpu": pairs(c) / t / V / 1e6,
                 "staging_s": stage_s, "staging_GBps": stage_gbs, "billed_over_derived": billed,
                 "engine_pre_fix": pre, "kind": kind, "basis": basis})


VCPU = {}
for p in tsv(os.path.join(OUT, "points.tsv")):
    N, price, V1 = int(p["N"]), float(p["price_per_h"]), int(p["vcpus_per_node"])
    pre, name = p["engine_pre_fix"], f"{p['type']} N={N}"
    c1 = min(float(x) for x in (p["c1_home_wall_s_median"], p["c1_striped_wall_s_median"]) if x not in ("-", ""))
    lpt, obs, bt = float(p["lpt_wall_s"]), float(p["observed_T_s"]), float(p["body_tail_s"])
    load = float(p["load_s"])
    fetch = float(p["fetch_s"])
    pre_batch = obs - lpt + bt  # boot, setup, manifest, input fetch, load, rendezvous, skew, body tail
    fx = {"fixed": pre_batch - load - fetch, "stage": load, "input": fetch, "prep": 0.0}
    add(1, "resident", "ours", name, c1, N, V1, price, pre, "measured", "sample 1 on its home node or striped, table loaded",
        ph={"fixed": 0, "stage": 0, "input": 0, "prep": 0.0, "classify": c1})
    add(1, "from-scratch", "ours", name, pre_batch + c1, N, V1, price, pre, "measured",
        "observed path to batch start (incl. rendezvous and skew) + c1 + body tail", f"{load:.0f}", f"{HASH_GB / load:.1f}",
        ph=dict(fx, classify=c1))
    add(100, "resident", "ours", name, lpt, N, V1, price, pre, "measured", "the LPT batch wall, table loaded",
        ph={"fixed": 0, "stage": 0, "input": 0, "prep": 0.0, "classify": lpt})
    te = obs + bt
    derived = N * price * te / 3600 / 100
    add(100, "from-scratch", "ours", name, te, N, V1, price, pre, "measured",
        "observed path (first launch to the last rank's end of batch 0) + body tail", f"{load:.0f}", f"{HASH_GB / load:.1f}",
        f"{float(p['measured_usd_per_sample_whole_run']) / derived:.2f}", ph=dict(fx, classify=lpt))
    add(1000, "resident", "ours", name, lpt * R1000, N, V1, price, pre, "placeholder", f"cohort-100 LPT wall x pairs ratio {R1000:.2f}")
    add(1000, "from-scratch", "ours", name, te - lpt + lpt * R1000 + float(p["fetch_s"]) * (R1000 - 1), N, V1, price, pre,
        "placeholder", f"cohort-100 path with the LPT wall and fetch scaled by {R1000:.2f}")

# E1, cohort 10 (8 x x8g.4xlarge), the critical-path rule from its records.
for cj in glob.glob(os.path.join(G, "*", "cohort.json")):
    c = json.load(open(cj))
    d = os.path.dirname(cj)
    if c.get("spec") != "runs/g3-e1.json" or not os.path.exists(os.path.join(d, "tables", "tidy.tsv")):
        continue
    tidy = tsv(os.path.join(d, "tables", "tidy.tsv"))
    S = {}
    for r in tidy:
        if r["invocation"] == "c10" and r["kind"] == "sample":
            S.setdefault((r["rank"], r["batch"], r["sample"]), {})[r["metric"]] = r["value"]
    mans = [json.load(open(os.path.join(G, m["run_id"], "manifest.json"))) for m in c["members"]]
    if not all("inv-c10" in phases(m) for m in mans):
        continue  # an attempt that ended before its c10 invocation
    price, N = float(mans[0]["truffle_price_usd_per_hour"]), int(c["nodes"])
    first = min(ts(m["instance"]["launch_time"]) for m in mans)
    pre = prefix(c.get("commit", ""))
    for b in ("0", "1"):
        ends, starts = [], []
        for k, m in enumerate(mans):
            st = ts(phases(m)["inv-c10"]["start"])
            mine = [v for (rk, bb, s_), v in S.items() if rk == str(k) and bb == b and v.get("role") == "home"]
            if mine:
                ends.append(st + dt.timedelta(seconds=max(float(v["start_s"]) + float(v["wall_s"]) for v in mine)))
                starts.append(st + dt.timedelta(seconds=min(float(v["start_s"]) for v in mine)))
        if not ends:
            continue
        wall = (max(ends) - min(starts)).total_seconds()
        crit = (max(ends) - first).total_seconds()
        load = max(float(r["value"]) for r in tidy if r["invocation"] == "c10" and r["kind"] == "phase"
                   and r["metric"].startswith("shard-load-") and not r["metric"].endswith(".start_s"))
        name = f"E1 {c['instance_type']} N={N} c10 batch {b}"
        add(10, "resident", "ours", name, wall, N, 16, price, pre, "measured", "E1 c10 batch wall (parallel j mod N, SDK)",
            ph={"fixed": 0, "stage": 0, "input": 0, "prep": 0.0, "classify": wall})
        add(10, "from-scratch", "ours", name, crit, N, 16, price, pre, "measured",
            "first launch to the last rank's end of the batch; E1's c10 invocation followed its three c1 invocations, "
            "whose time is in this path", f"{load:.0f}", f"{HASH_GB / load:.1f}",
            ph={"fixed": crit - wall - load, "stage": load, "input": 0.0, "prep": 0.0, "classify": wall})

# Upstream: U1 (tmpfs-resident, x8g.24xlarge, 96 vCPU) and U2 (NVMe, r8gd.16xlarge, 64 vCPU), from
# their records; then the variants the probes measured (staging rate, S3 contention, decompression).
BYTES = {r["run"]: int(r["bytes_1"]) + int(r["bytes_2"]) for r in runs}


def logline(d, pat):
    for ln in open(os.path.join(d, "log", "run.log"), errors="replace"):
        mm = re.search(pat, ln)
        if mm:
            return mm
    return None


def etag_s(d):
    mm = logline(d, r"etag hash\.k2d: (\{.*\})")
    return json.loads(mm.group(1))["seconds"] if mm else 0.0


def node_record(d, kind):
    """The node's measured fixed costs: boot+setup, table staging (its ETag check out), input rate."""
    m = json.load(open(os.path.join(d, "manifest.json")))
    ph = phases(m)
    e = etag_s(d)
    rec = {"dir": d, "price": float(m["truffle_price_usd_per_hour"]), "boot_setup": boot_of(m) + ph["setup"]["seconds"],
           "stage": ph["fetch-db"]["seconds"] - e, "etag": e, "fetch_db": ph["fetch-db"]["seconds"]}
    if kind == "u1":
        mm = logline(d, r"inputs staged and verified: (\d+) files, ([0-9.]+) GB")
        rec["in_rate"] = float(mm.group(2)) * 1e9 / ph["fetch-inputs"]["seconds"]  # bytes/s, measured
        rec["in_note"] = f"U1's input fetch, {float(mm.group(2)):.1f} GB in {ph['fetch-inputs']['seconds']:.0f} s"
    return rec


U1 = U2 = None
for jl in glob.glob(os.path.join(G, "*", "out", "u1.jsonl")):
    d = os.path.dirname(os.path.dirname(jl))
    if os.path.exists(os.path.join(d, "tables", "samples.tsv")):
        U1 = node_record(d, "u1")
        U1["prep"] = {}
        for x in tsv(os.path.join(d, "tables", "prep.tsv")):
            U1["prep"][x["sample"]] = min(U1["prep"].get(x["sample"], 1e18), float(x["seconds"]))
        cfg = {}
        for r in tsv(os.path.join(d, "tables", "samples.tsv")):
            if r["rung"].startswith("ref") or r["exit"] != "0":
                continue
            cfg.setdefault(re.sub(r"-r\d+$", "", r["rung"]), {"input": r["input"], "w": {}})["w"].setdefault(
                r["sample"], []).append(float(r["wall_s"]))
        U1["cfg"] = {k: {"input": v["input"], "P": int(re.search(r"-p(\d+)-", k).group(1)) if "-p" in k and re.search(r"-p(\d+)-", k) else 1,
                         "w": {s: statistics.median(x) for s, x in v["w"].items()}} for k, v in cfg.items()}
        U1["rungs"] = tsv(os.path.join(d, "tables", "rungs.tsv"))
for sm in glob.glob(os.path.join(G, "*", "out", "g2-u2", "summary.tsv")):
    d = os.path.dirname(os.path.dirname(os.path.dirname(sm)))
    U2 = node_record(d, "u2")
    U2["in_rate"], U2["in_note"] = U1["in_rate"], "U1's measured input rate (U2 fetched no cohort beyond sample 1)"
    ref = [r for r in tsv(sm) if r["input"].startswith("SRR5935740")]
    U2["warm"] = min((r for r in ref if r["state"] == "warm"), key=lambda r: float(r["wall_med"]))
    U2["cold"] = min((r for r in ref if r["state"] == "cold"), key=lambda r: float(r["wall_med"]))

# Probe tables (results/g3/<run>/tables/probe-*.tsv, written by the probes' post scripts).
PROBE = {}
for f in sorted(glob.glob(os.path.join(G, "*", "tables", "probe-*.tsv"))):
    PROBE.setdefault(os.path.basename(f)[6:-4], []).append((os.path.dirname(os.path.dirname(f)), tsv(f)))
# (a) best-practice staging onto tmpfs on one x8g.24xlarge: GB/s of the fastest tool.
STAGE_A = None
if "staging" in PROBE:
    d, t = PROBE["staging"][-1]
    okr = [r for r in t if r["ok"] == "yes"]
    if okr:
        bb = max(okr, key=lambda r: float(r["gbps"]))
        STAGE_A = {"gbps": float(bb["gbps"]), "tool": bb["tool"], "run": os.path.basename(d), "etag_s": bb.get("etag_s", "-")}
# (b) the S3 contention curve: per-node rates at N (the slowest node gives the max-over-N term).
CONT = None
if "contention" in PROBE:
    CONT = {}
    for d, t in PROBE["contention"]:
        for r in t:
            CONT[int(r["N"])] = {"min": float(r["node_min_gbps"]), "med": float(r["node_median_gbps"]),
                                 "agg": float(r["aggregate_gbps"]), "run": os.path.basename(d), "nic": r.get("nic_gbps", "-")}
# (c) decompression tools on one sample: time relative to pigz on the same node, and identity.
# Ratios are to pigz -p 16 with the mates one after the other (seq), as U1's preparation ran;
# DECOMP_CONC is each tool with both mates at once (the wrapper's two pipes), to the same base.
DECOMP, DECOMP_CONC = {}, {}
if "decomp" in PROBE:
    d, t = PROBE["decomp"][-1]
    base = [float(r["seconds"]) for r in t if r["tool"].startswith("pigz")]
    for r in t:
        if base and r["identical"] == "yes":
            DECOMP[r["tool"]] = {"ratio": float(r["seconds"]) / min(base), "s": float(r["seconds"]), "run": os.path.basename(d)}
    if "decomp-conc" in PROBE:
        for r in PROBE["decomp-conc"][-1][1]:
            if base and r["identical"] == "yes":
                DECOMP_CONC[r["tool"]] = {"ratio": float(r["seconds"]) / min(base), "s": float(r["seconds"])}


def stage_rate(variant, N):
    """Per-node table staging GB/s for the slowest node of N (the max-over-N term), by variant."""
    if variant == "measured":
        return None  # the node's own recorded staging seconds (ETag out), N-independent
    a = STAGE_A["gbps"]
    if variant == "probe-a":
        return a
    # probe-a scaled by the measured contention factor f(N) = the slowest node's rate at N over a
    # lone node's (probe (b)'s N = 1, same type), piecewise-linear in N between the probed N;
    # beyond the largest probed N, that stage's aggregate shared over N.
    one = CONT[1]["med"]
    pts = sorted((n, min(1.0, v["min"] / one)) for n, v in CONT.items())
    nmax = pts[-1][0]
    if N >= nmax:
        return a * min(pts[-1][1], CONT[nmax]["agg"] / N / one)
    for (n0, f0), (n1, f1) in zip(pts, pts[1:]):
        if n0 <= N <= n1:
            return a * (f0 + (f1 - f0) * (N - n0) / (n1 - n0))


def prep_of(sample, tool, conc=False):
    p = U1["prep"].get(sample, 0.0)
    if conc:
        return p * DECOMP_CONC[tool]["ratio"]
    return p if tool == "pigz" else p * DECOMP[tool]["ratio"]


SP = "upstream sample-parallel (derived from single-node measurements)"


def schedule(items, N, P, cold_x=0.0, overlap=False):
    """LPT over N x P identical slots (slot k on node k mod N; the largest samples go round-robin
    to the nodes). items: (sample, prep_s, classify_s). Per node: its slots' spans and its input
    bytes. A slot's first sample takes (1 + cold_x) x its classify wall (U2's cold first sample).
    overlap: "pipelined" (a slot's next sample decompresses during the current classify) or
    "stream" (decompression streams into classify, the wrapper's pipes: max(prep, classify))."""
    h = [(0.0, k) for k in range(N * P)]
    slot = {k: [] for k in range(N * P)}
    for s_, pr, cl in sorted(items, key=lambda x: -(x[1] + x[2])):
        t, k = heapq.heappop(h)
        slot[k].append((s_, pr, cl * (1 + cold_x) if not slot[k] else cl))
        heapq.heappush(h, (t + pr + cl, k))
    nodes = []
    for n in range(N):
        span = prep = cls = 0.0
        byt = 0
        for k in range(n, N * P, N):
            js = slot[k]
            if not js:
                continue
            if overlap == "stream":
                sp_ = sum(max(pr, cl) for _, pr, cl in js)
            elif overlap:
                sp_ = js[0][1] + sum(max(js[i][2], js[i + 1][1]) for i in range(len(js) - 1)) + js[-1][2]
            else:
                sp_ = sum(pr + cl for _, pr, cl in js)
            if sp_ > span:
                span, prep, cls = sp_, sum(pr for _, pr, _ in js), sum(cl for _, _, cl in js)
            byt += sum(BYTES[s_] for s_, _, _ in js)
        nodes.append({"span": span, "prep": prep, "classify": cls, "bytes": byt})
    return nodes


def evaluate(node, items, N, P, regime, svar, cold_x=0.0, overlap=False):
    """(time, phases of the critical node) for N nodes of a type; from scratch every node stages."""
    nodes = schedule(items, N, P, cold_x, overlap)
    best_t, ph_ = -1, None
    for nd in nodes:
        if regime == "resident":
            t = nd["span"]
            p = {"fixed": 0.0, "stage": 0.0, "input": 0.0}
        else:
            r = stage_rate(svar, N)
            st = node["stage"] if r is None else HASH_GB / r
            p = {"fixed": node["boot_setup"], "stage": st, "input": nd["bytes"] / node["in_rate"]}
            t = p["fixed"] + p["stage"] + p["input"] + nd["span"]
        if t > best_t:
            best_t = t
            ph_ = dict(p, prep=nd["prep"], classify=nd["classify"], span=nd["span"])
    return best_t, ph_


def u1_items(cfgname, c, tool, conc=False):
    cf = U1["cfg"][cfgname]
    out = []
    for s_ in order[:c]:
        if s_ not in cf["w"]:
            return None
        out.append((s_, prep_of(s_, tool, conc) if cf["input"] == "fq" else 0.0, cf["w"][s_]))
    return out


def u2_items(c):
    per_pair = float(U2["warm"]["wall_med"]) / float(U2["warm"]["pairs"])
    return [(r["run"], 0.0, int(r["read_count"]) * per_pair) for r in runs if int(r["rank"]) <= c]


# Single-node upstream as measured (pass walls of U1's rungs, U2's warm and cold rungs).
for r in U1["rungs"]:
    c = int(r["cohort"])
    if r["rung"].startswith("ref") or (r["rung"].startswith("A-c1") and "(n=" not in r["rung"]):
        continue  # A rungs enter through their n=3 medians
    cls = float(r["pass_wall_s"])
    prep = sum(U1["prep"].get(s_, 0) for s_ in order[:c]) if r["input"] == "fq" else 0.0
    kind = "measured" if r["basis"] == "measured" else "modelled"
    label = f"U1 {r['rung']}" + (" (+fq prep)" if r["input"] == "fq" else "")
    add(c, "resident", "upstream", label, prep + cls, 1, 96, U1["price"], "-", kind, "U1 pass on the tmpfs-resident table",
        ph={"fixed": 0, "stage": 0, "input": 0, "prep": prep, "classify": cls})
    inp = sum(BYTES[s_] for s_ in order[:c]) / U1["in_rate"]
    add(c, "from-scratch", "upstream", label, U1["boot_setup"] + U1["stage"] + inp + prep + cls, 1, 96, U1["price"], "-", kind,
        f"U1 boot+setup + RODA onto tmpfs (its {U1['etag']:.1f} s ETag check out) + the cohort's input bytes at {U1['in_note']} + the pass",
        f"{U1['stage']:.0f}", f"{HASH_GB / U1['stage']:.2f}",
        ph={"fixed": U1["boot_setup"], "stage": U1["stage"], "input": inp, "prep": prep, "classify": cls})
    if c == 100 and kind == "measured":
        add(1000, "resident", "upstream", label, (prep + cls) * R1000, 1, 96, U1["price"], "-", "modelled-infeasible",
            f"cohort-100 pass x {R1000:.2f}; infeasible as specified (input plus table exceed the node's tmpfs)")
add(1, "resident", "upstream", f"U2 warm T={U2['warm']['threads']}", float(U2["warm"]["wall_med"]), 1, 64, U2["price"], "-",
    "measured", "U2 warm -M wall (page cache partly warm)",
    ph={"fixed": 0, "stage": 0, "input": 0, "prep": 0, "classify": float(U2["warm"]["wall_med"])})
inp = BYTES[order[0]] / U2["in_rate"]
cw = float(U2["cold"]["wall_med"])
add(1, "from-scratch", "upstream", f"U2 cold T={U2['cold']['threads']}", U2["boot_setup"] + U2["stage"] + inp + cw, 1, 64,
    U2["price"], "-", "measured",
    f"U2 boot+setup + RODA onto NVMe (its {U2['etag']:.1f} s ETag check out) + sample 1's input at {U2['in_note']} + the cold -M wall",
    f"{U2['stage']:.0f}", f"{HASH_GB / U2['stage']:.2f}",
    ph={"fixed": U2["boot_setup"], "stage": U2["stage"], "input": inp, "prep": 0, "classify": cw})

# Upstream variants: N nodes (1 = single node) x staging variant x decompression option, per cohort.
SVARS = ["measured"] + (["probe-a"] if STAGE_A else []) + (["probe-a+b"] if STAGE_A and CONT else [])
SV_LABEL = {"measured": "staging as measured (aws s3 cp CRT; ETag out)",
            "probe-a": f"staging at probe (a)'s {STAGE_A['gbps']:.2f} GB/s ({STAGE_A['tool']}), no contention" if STAGE_A else "",
            "probe-a+b": "staging at probe (a)'s rate capped by probe (b)'s S3 contention at N (slowest node)"}
TOOLS = ["pigz"] + sorted(DECOMP)
sweep = []
for c in (1, 10, 100):
    for svar in SVARS:
        for tool in TOOLS:
            if tool != "pigz" and tool.startswith("pigz"):
                continue
            for overlap in (False, "pipelined", "stream"):
                if overlap == "stream" and tool not in DECOMP_CONC:
                    continue
                for cfgname, cf in U1["cfg"].items():
                    if cf["input"] != "fq" and (tool != "pigz" or overlap):
                        continue  # decompression options and overlap apply to the fq path only
                    items = u1_items(cfgname, c, tool, overlap == "stream")
                    if items is None:
                        continue
                    for N in range(1, c + 1):
                        for regime in ("resident", "from-scratch"):
                            if regime == "resident" and svar != "measured":
                                continue  # staging does not enter the resident regime
                            t, phs = evaluate(U1, items, N, cf["P"], regime, svar, overlap=overlap)
                            sweep.append({"cohort": c, "regime": regime, "node": "x8g.24xlarge (U1, tmpfs)", "config": cfgname,
                                          "svar": svar, "tool": tool if cf["input"] == "fq" else "in-process gzip",
                                          "overlap": overlap, "slots_per_node": cf["P"], "N": N, "time_s": t,
                                          "usd_per_sample": N * U1["price"] * t / 3600 / c, "price": U1["price"], "vcpus": 96,
                                          "ph": phs})
    cold_x = float(U2["cold"]["wall_med"]) / float(U2["warm"]["wall_med"]) - 1
    for N in range(1, c + 1):
        for regime in ("resident", "from-scratch"):
            t, phs = evaluate(U2, u2_items(c), N, 1, regime, "measured", cold_x if regime == "from-scratch" else 0.0)
            sweep.append({"cohort": c, "regime": regime, "node": "r8gd.16xlarge (U2, NVMe)",
                          "config": f"warm T={U2['warm']['threads']}, first sample per node cold T={U2['cold']['threads']}",
                          "svar": "measured", "tool": "in-process gzip", "overlap": False, "slots_per_node": 1, "N": N,
                          "time_s": t, "usd_per_sample": N * U2["price"] * t / 3600 / c, "price": U2["price"], "vcpus": 64,
                          "ph": phs})

# The labelled upstream variants that enter the bests: per cohort, regime, node type, staging
# variant and decompression option, the N that minimises time and the N that minimises $/sample.
for key in sorted({(s["cohort"], s["regime"], s["node"], s["svar"], s["tool"], str(s["overlap"])) for s in sweep}):
    sel = [s for s in sweep if (s["cohort"], s["regime"], s["node"], s["svar"], s["tool"], str(s["overlap"])) == key]
    picks = {}
    for why, s in (("min time", min(sel, key=lambda s: (s["time_s"], s["N"]))),
                   ("min $", min(sel, key=lambda s: (s["usd_per_sample"], s["N"])))):
        picks.setdefault(id(s), [s, []])[1].append(why)
    for s, whys in picks.values():
        c, regime = key[0], key[1]
        if c == 1 and s["N"] == 1 and s["svar"] == "measured" and s["tool"] in ("pigz", "in-process gzip") and not s["overlap"]:
            continue  # the measured single-node rows already carry this point
        st = ("-", "-")
        if regime == "from-scratch":
            st = (f"{s['ph']['stage']:.0f}", f"{HASH_GB / s['ph']['stage']:.2f}")
        dec = s["tool"] + {False: "", "pipelined": ", decompression pipelined ahead of classify",
                           "stream": ", gz streamed through the wrapper's pipes with this tool as gzip (fq classify wall, "
                                     "both mates at once)"}[s["overlap"]]
        lab = (f"{SP if s['N'] > 1 else 'upstream single node (derived)'}: {s['node']} N={s['N']}, {s['config']}; "
               f"{SV_LABEL[s['svar']] if regime == 'from-scratch' else 'table resident'}; {dec} ({', '.join(whys)})")
        # Probe (a)'s rate without probe (b)'s contention is not physical for N > 1 nodes staging at
        # once: it stays in the lever table, out of the bests, the Pareto sets and the kill.
        kind = "derived-uncapped" if (s["svar"] == "probe-a" and s["N"] > 1 and CONT) else "derived"
        add(c, regime, "upstream", lab, s["time_s"], s["N"], s["vcpus"], s["price"], "-", kind,
            f"LPT of measured per-sample walls over N x {s['slots_per_node']} slots; input bytes per node at {U1['in_note']}"
            + ("; per-node staging paid N times ($), once in time" if regime == "from-scratch" else "; table already resident on each node"),
            *st, ph=s["ph"], extra={"svar": s["svar"], "tool": s["tool"], "overlap": s["overlap"], "N": s["N"],
                                    "node_rec": U1 if s["node"].startswith("x8g") else U2, "c": c})

# Per-axis bests with the attribution, the phase split, the staging break-even, and the kill condition.
def phase_text(o, u):
    po, pu = o["ph"], u["ph"]
    if not po or not pu:
        return "-"
    fo, fu = po["fixed"] + po["stage"] + po["input"], pu["fixed"] + pu["stage"] + pu["input"]
    r = lambda a, b: f"{a / b:.2f}x" if b > 0 else "-"
    tot_u = fu + pu["prep"] + pu["classify"]
    share = pu["prep"] / tot_u if tot_u else 0
    t = []
    if fu or fo:
        t.append(f"fixed+staging+input up {fu:.0f} s / ours {fo:.0f} s = {r(fu, fo)} (staging up {pu['stage']:.0f} / ours {po['stage']:.0f})")
    t.append(f"decompression/prep up {pu['prep']:.1f} s / ours in classify")
    t.append(f"classify up {pu['classify']:.1f} s / ours {po['classify']:.1f} s = {r(pu['classify'], po['classify'])}")
    t.append(f"prep+classify up {pu['prep'] + pu['classify']:.1f} / ours {po['classify']:.1f} = {r(pu['prep'] + pu['classify'], po['classify'])}")
    if share > 0.5 or (pu["prep"] > pu["classify"]):
        t.append(f"upstream critical node bound by preparation ({pu['prep']:.0f} s prep vs {pu['classify']:.0f} s classify)")
    return "; ".join(t)


def breakeven(o, u, axis):
    """Upstream's staging GB/s at which the ratio would be 5x (the kill line) and 1x, the rest of
    the upstream point held fixed."""
    pu = u["ph"]
    if not pu or not pu["stage"]:
        return "-"
    rest = u["time_s"] - pu["stage"]
    out = []
    for k in (5, 1):
        if axis == "time":
            tgt = k * o["time_s"]
        else:
            tgt = k * o["usd_per_sample"] * 3600 * u["cohort"] / (u["usd_per_vcpu_h"] * u["fleet_vcpus"])
        den = tgt - rest
        out.append(f"{k}x at {HASH_GB / den:.2f} GB/s" if den > 0 else f"{k}x unreachable at any staging rate")
    return f"{axis}: " + ", ".join(out) + f" (now {HASH_GB / pu['stage']:.2f} GB/s)"


def law5(o, u, axis):
    if axis == "time":
        w, e = o["fleet_vcpus"] / u["fleet_vcpus"], o["mpairs_per_s_per_vcpu"] / u["mpairs_per_s_per_vcpu"]
        txt = (f"width {w:.2f} (V {o['fleet_vcpus']} vs {u['fleet_vcpus']}) x per-vCPU {e:.2f} "
               f"({1000 * o['mpairs_per_s_per_vcpu']:.2f} vs {1000 * u['mpairs_per_s_per_vcpu']:.2f} kpairs/s/vCPU)")
    else:
        pc, e = u["usd_per_vcpu_h"] / o["usd_per_vcpu_h"], o["mpairs_per_s_per_vcpu"] / u["mpairs_per_s_per_vcpu"]
        txt = (f"price/vCPU-h {pc:.2f} (${u['usd_per_vcpu_h']:.4f} vs ${o['usd_per_vcpu_h']:.4f}) x per-vCPU {e:.2f} "
               f"({1000 * o['mpairs_per_s_per_vcpu']:.2f} vs {1000 * u['mpairs_per_s_per_vcpu']:.2f} kpairs/s/vCPU)")
    if u["kind"] == "derived" and u["extra"].get("N", 1) > 1:
        txt = ("[not a lever attribution: upstream's V is N x node vCPUs at the floor, N set by the smallest-N tie-break] "
               + txt)
    return txt


best, kills = [], {}
for regime in ("resident", "from-scratch"):
    kills[regime] = True
    for c in (1, 10, 100, 1000):
        sel = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["kind"] not in ("placeholder",)]
        ours = [r for r in sel if r["side"] == "ours"]
        up = [r for r in sel if r["side"] == "upstream" and r["kind"] not in ("modelled-infeasible", "derived-uncapped")]
        if c == 1000:
            best.append([regime, c, "placeholder only (ours); upstream modelled and infeasible as specified"] + ["-"] * 9)
            continue
        if not ours or not up:
            best.append([regime, c, "no data on one side"] + ["-"] * 9)
            continue
        pref = lambda r: r["kind"] != "measured"  # on a tie, the measured point
        ot, ut = min(ours, key=lambda r: (r["time_s"], pref(r))), min(up, key=lambda r: (r["time_s"], pref(r)))
        oc, uc = (min(ours, key=lambda r: (r["usd_per_sample"], pref(r))),
                  min(up, key=lambda r: (r["usd_per_sample"], pref(r))))
        rt, rc = ut["time_s"] / ot["time_s"], uc["usd_per_sample"] / oc["usd_per_sample"]
        kill = rt < 5 and rc < 5
        kills[regime] = kills[regime] and kill
        refs = []
        if c == 1:
            refs.append(f"time vs ~6-20x: {'below 6x' if rt < 6 else ('6-20x' if rt <= 20 else 'above 20x')}")
        if c >= 100:
            refs.append(f"$ vs ~20x: {'below' if rc < 20 else 'at or above'}")
        pre = sorted({ot["engine_pre_fix"], oc["engine_pre_fix"]})
        be = "-"
        if regime == "from-scratch":
            be = breakeven(ot, ut, "time") + "; " + breakeven(oc, uc, "$")
        best.append([regime, c,
                     f"time: ours {ot['point']} {ot['time_s']:.1f} s, upstream [{ut['kind']}] {ut['point']} {ut['time_s']:.1f} s",
                     f"{rt:.3f} = " + law5(ot, ut, "time"), phase_text(ot, ut),
                     f"$: ours {oc['point']} ${oc['usd_per_sample']:.5f}, upstream [{uc['kind']}] {uc['point']} ${uc['usd_per_sample']:.5f}",
                     f"{rc:.3f} = " + law5(oc, uc, "$"), phase_text(oc, uc), be,
                     "; ".join(refs) or "-", f"under 5x on both: {'yes' if kill else 'no'}",
                     f"engine pre-fix: {'/'.join(pre)}"])

# Kill sensitivity by upstream lever (Law 5): the verdict as upstream's levers are added one at a time.
def uset(r):
    """The smallest lever set an upstream row belongs to."""
    if r["kind"] in ("measured", "modelled"):
        return 0
    e = r["extra"]
    dec = e.get("tool") in ("pigz", "in-process gzip") and not e.get("overlap")
    if e.get("svar") == "measured" and dec:
        return 1
    if dec:
        return 2 if e.get("svar") == "probe-a" else 3
    return {"measured": 4, "probe-a": 5}.get(e.get("svar"), 6)


LEVERS = [("single node as measured (U1, U2)", {0}),
          ("+ sample-parallel N (derived; staging as measured, pigz)", {0, 1}),
          ("+ staging at probe (a)'s rate, contention ignored (not physical for N > 1; shown for attribution)", {0, 1, 2}),
          ("+ staging at probe (a)'s rate x probe (b)'s contention f(N)", {0, 1, 3}),
          ("+ decompression options (probe (c)), staging as measured", {0, 1, 4}),
          ("+ decompression options, staging at probe (a) x contention (all measured levers)", {0, 1, 3, 4, 6})]
sens = []
for regime in ("resident", "from-scratch"):
    for name, allowed in LEVERS:
        cells, kill_k = [], True
        for c in (1, 10, 100):
            ours = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["side"] == "ours" and r["kind"] == "measured"]
            up = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["side"] == "upstream"
                  and r["kind"] not in ("placeholder", "modelled-infeasible") and uset(r) in allowed
                  and (r["kind"] != "derived-uncapped" or 2 in allowed)]
            if not ours or not up:
                cells.append("-")
                continue
            rt = min(u["time_s"] for u in up) / min(o["time_s"] for o in ours)
            rc = min(u["usd_per_sample"] for u in up) / min(o["usd_per_sample"] for o in ours)
            kill_k = kill_k and rt < 5 and rc < 5
            cells.append(f"time {rt:.2f}x, $ {rc:.2f}x")
        sens.append([regime, name] + cells + ["MET" if kill_k else "not met"])

# Pareto sets per cohort, regime and side.
pareto = []
for c in (1, 10, 100):
    for regime in ("resident", "from-scratch"):
        for side in ("ours", "upstream"):
            sel = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["side"] == side and r["kind"] in ("measured", "derived")]
            for r in sel:
                dom = any(o is not r and o["time_s"] <= r["time_s"] and o["usd_per_sample"] <= r["usd_per_sample"]
                          and (o["time_s"] < r["time_s"] or o["usd_per_sample"] < r["usd_per_sample"]) for o in sel)
                if not dom:
                    pareto.append([c, regime, side, r["point"], f"{r['time_s']:.2f}", f"{r['usd_per_sample']:.6f}",
                                   r["fleet_vcpus"], f"{r['usd_per_vcpu_h']:.4f}", f"{r['mpairs_per_s_per_vcpu']:.4f}",
                                   r["engine_pre_fix"], r["kind"]])

os.makedirs(OUT, exist_ok=True)
head = ["cohort", "regime", "side", "point", "time_s", "usd_per_sample_derived", "fleet_vcpus", "usd_per_vcpu_h",
        "mpairs_per_s_per_vcpu", "staging_s", "staging_GBps", "billed_over_derived", "engine_pre_fix", "kind",
        "ph_fixed_s", "ph_staging_s", "ph_input_s", "ph_prep_s", "ph_classify_s", "basis"]
PH = lambda r, k: f"{r['ph'][k]:.2f}" if r["ph"] else "-"
with open(os.path.join(OUT, "frontier.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(head)
    for r in sorted(rows, key=lambda r: (r["cohort"], r["regime"], r["side"], r["time_s"])):
        w.writerow([r["cohort"], r["regime"], r["side"], r["point"], f"{r['time_s']:.2f}", f"{r['usd_per_sample']:.6f}",
                    r["fleet_vcpus"], f"{r['usd_per_vcpu_h']:.4f}", f"{r['mpairs_per_s_per_vcpu']:.4f}", r["staging_s"],
                    r["staging_GBps"], r["billed_over_derived"], r["engine_pre_fix"], r["kind"]]
                   + [PH(r, k) for k in ("fixed", "stage", "input", "prep", "classify")] + [r["basis"]])
ph_ = ["cohort", "regime", "side", "point", "time_s", "usd_per_sample_derived", "fleet_vcpus", "usd_per_vcpu_h",
       "mpairs_per_s_per_vcpu", "engine_pre_fix", "kind"]
with open(os.path.join(OUT, "pareto.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(ph_)
    w.writerows(pareto)
with open(os.path.join(OUT, "upstream_sp_sweep.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["cohort", "regime", "node", "config", "staging_variant", "decompression", "overlap", "slots_per_node", "N",
                "time_s", "usd_per_sample_derived", "crit_fixed_s", "crit_staging_s", "crit_input_s", "crit_prep_s",
                "crit_classify_s"])
    for s in sweep:
        w.writerow([s["cohort"], s["regime"], s["node"], s["config"], s["svar"], s["tool"], s["overlap"] or "no",
                    s["slots_per_node"], s["N"], f"{s['time_s']:.2f}", f"{s['usd_per_sample']:.6f}"]
                   + [f"{s['ph'][k]:.2f}" for k in ("fixed", "stage", "input", "prep", "classify")])
gc = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
with open(os.path.join(OUT, "frontier.md"), "w") as fh:
    fh.write("# H-main per-axis bests and Pareto sets (generated by scripts/lib/g3_frontier.py)\n\n")
    fh.write("**Every engine point here is pre-fix (#44) until regenerated.**\n\n")
    fh.write(f"Generated at {gc}. Do not edit: rerun `make g3-frontier`. Every point is in frontier.tsv; the Pareto "
             "sets are in pareto.tsv.\n\n")
    fh.write(__doc__.split("Definitions (generated into frontier.md):")[1].strip().replace("\n  ", "\n") + "\n\n")
    fh.write("## Per-axis bests\n\n")
    hs = ["regime", "cohort", "best time (each side)", "time ratio = width x per-vCPU efficiency", "time: phase split",
          "best $/sample, derived (each side)", "$ ratio = price per vCPU-hour x per-vCPU efficiency", "$: phase split",
          "staging break-even (upstream GB/s for 5x and 1x)", "registered reference", "kill check", "provenance"]
    fh.write("| " + " | ".join(hs) + " |\n|" + "---|" * len(hs) + "\n")
    for s in best:
        fh.write("| " + " | ".join(str(x) for x in s) + " |\n")
    for regime, k in kills.items():
        fh.write(f"\nKill condition, {regime} (under 5x on both axes at every measured cohort size 1, 10, 100): "
                 f"{'MET' if k else 'not met'}.\n")
    fh.write("\n## Kill condition by upstream lever (each row adds one lever to the first two; ratios are upstream best / "
             "ours best; the last row is every measured lever together and is the one the verdicts above use)\n\n")
    fh.write("| regime | upstream levers | cohort 1 | cohort 10 | cohort 100 | kill |\n|---|---|---|---|---|---|\n")
    for r in sens:
        fh.write("| " + " | ".join(r) + " |\n")
    fh.write("\nThe decompression rows rest on a derived combination not run end to end: U1's fq classify walls with "
             "probe (c)'s decompression time on the same core type (gz streamed: the slower of the two per sample); the "
             "wrapper calls `gzip -dc`, so it needs a gzip-compatible decompressor on PATH.\n")
    fh.write("\nE1's cohort-10 from-scratch path includes its three earlier cohort-1 invocations (it ran c10 last), "
             "so it overstates a cohort-10-only run.\n")
    fh.write("\n## Billed / derived (where a run's bill is known)\n\n")
    fh.write("| point | cohort | regime | billed / derived |\n|---|---|---|---|\n")
    for r in rows:
        if r["billed_over_derived"] != "-":
            fh.write(f"| {r['point']} | {r['cohort']} | {r['regime']} | {r['billed_over_derived']} |\n")
    fh.write("\nUpstream's runs (U1, U2) each ran many rungs, so their bills are not separable per rung: not known.\n")
    fh.write("\n## Pareto sets (non-dominated in time and derived $/sample, per side; measured and derived points, the kind column says which)\n\n")
    fh.write("| " + " | ".join(ph_) + " |\n|" + "---|" * len(ph_) + "\n")
    for p in pareto:
        fh.write("| " + " | ".join(str(x) for x in p) + " |\n")
print(f"g3_frontier: {len(rows)} points, {len(pareto)} Pareto points -> {OUT}/frontier.{{tsv,md}}, pareto.tsv, upstream_sp_sweep.tsv")
