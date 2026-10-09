#!/usr/bin/env python3
"""H-main per-axis bests and Pareto sets (#25): ours against upstream at its best, per cohort
size and regime, from the record only.

  g3_frontier.py   -> results/g3/campaign/frontier.{tsv,md}, pareto.tsv

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
    its fastest preparation, prep.tsv). Input sha256 verification is inside both sides' fetch
    phases; U1's ETag computation is outside its timed walls; ours computes none.
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
  - Registered reference points (#25 H-main): ~20x lower $/sample at cohort >= 100; ~6x (Tier A)
    to 20x faster for a single sample. Kill condition: under 5x on both axes at every cohort size,
    evaluated per regime on the measured cohort sizes (1, 10, 100).
  - Cohort 1000: ours is a placeholder only (Scott's decision: the engine side uses real
    samples), extrapolated from cohort 100 by the pairs ratio and never a best. Upstream's
    cohort-1000 model is infeasible as specified: about 1.4 TB of fq input plus RODA's 1.19 TB
    table on a 1536 GiB tmpfs node; it is shown, flagged, for completeness.
"""
import csv, datetime as dt, glob, json, os, subprocess

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


def add(c, regime, side, point, t, nodes, vcpus, price_h, pre, kind, basis, stage_s="-", stage_gbs="-", billed="-"):
    V = nodes * vcpus
    rows.append({"cohort": c, "regime": regime, "side": side, "point": point, "time_s": t,
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
    add(1, "resident", "ours", name, c1, N, V1, price, pre, "measured", "sample 1 on its home node or striped, table loaded")
    add(1, "from-scratch", "ours", name, obs - lpt + c1 + bt, N, V1, price, pre, "measured",
        "observed path to batch start (incl. rendezvous and skew) + c1 + body tail", f"{load:.0f}", f"{HASH_GB / load:.1f}")
    add(100, "resident", "ours", name, lpt, N, V1, price, pre, "measured", "the LPT batch wall, table loaded")
    te = obs + bt
    derived = N * price * te / 3600 / 100
    add(100, "from-scratch", "ours", name, te, N, V1, price, pre, "measured",
        "observed path (first launch to the last rank's end of batch 0) + body tail", f"{load:.0f}", f"{HASH_GB / load:.1f}",
        f"{float(p['measured_usd_per_sample_whole_run']) / derived:.2f}")
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
        add(10, "resident", "ours", name, wall, N, 16, price, pre, "measured", "E1 c10 batch wall (parallel j mod N, SDK)")
        add(10, "from-scratch", "ours", name, crit, N, 16, price, pre, "measured",
            "first launch to the last rank's end of the batch; E1's c10 invocation followed its three c1 invocations, "
            "whose time is in this path", f"{load:.0f}", f"{HASH_GB / load:.1f}")

# Upstream: U1 (tmpfs-resident, x8g.24xlarge, 96 vCPU) and U2 (NVMe, r8gd.16xlarge, 64 vCPU).
for jl in glob.glob(os.path.join(G, "*", "out", "u1.jsonl")):
    d = os.path.dirname(os.path.dirname(jl))
    if not os.path.exists(os.path.join(d, "tables", "rungs.tsv")):
        continue
    m = json.load(open(os.path.join(d, "manifest.json")))
    price = float(m["truffle_price_usd_per_hour"])
    ph = phases(m)
    stage = boot_of(m) + ph["setup"]["seconds"] + ph["fetch-db"]["seconds"] + ph["fetch-inputs"]["seconds"]
    prep = {}
    for x in tsv(os.path.join(d, "tables", "prep.tsv")):
        prep[x["sample"]] = min(prep.get(x["sample"], 1e18), float(x["seconds"]))
    for r in tsv(os.path.join(d, "tables", "rungs.tsv")):
        c = int(r["cohort"])
        if r["rung"].startswith("ref") or (r["rung"].startswith("A-c1") and "(n=" not in r["rung"]):
            continue  # A rungs enter through their n=3 medians
        t = float(r["pass_wall_s"])
        if r["input"] == "fq":
            t += sum(prep.get(s, 0) for s in order[:c])
        kind = "measured" if r["basis"] == "measured" else "modelled"
        label = f"U1 {r['rung']}" + (" (+fq prep)" if r["input"] == "fq" else "")
        fdb = ph["fetch-db"]["seconds"]
        add(c, "resident", "upstream", label, t, 1, 96, price, "-", kind, "U1 pass on the tmpfs-resident table")
        add(c, "from-scratch", "upstream", label, stage + t, 1, 96, price, "-", kind,
            "U1 boot+setup+RODA onto tmpfs+the input fetch+the pass", f"{fdb:.0f}", f"{HASH_GB / fdb:.1f}")
        if c == 100 and kind == "measured":
            add(1000, "resident", "upstream", label, t * R1000, 1, 96, price, "-", "modelled-infeasible",
                f"cohort-100 pass x {R1000:.2f}; infeasible as specified (input plus table exceed the node's tmpfs)")
for sm in glob.glob(os.path.join(G, "*", "out", "g2-u2", "summary.tsv")):
    d = os.path.dirname(os.path.dirname(os.path.dirname(sm)))
    m = json.load(open(os.path.join(d, "manifest.json")))
    price = float(m["truffle_price_usd_per_hour"])
    ph = phases(m)
    for r in tsv(sm):
        if not r["input"].startswith("SRR5935740"):
            continue
        t = float(r["wall_med"])
        lab = f"U2 {r['state']} T={r['threads']}"
        if r["state"] == "warm":
            add(1, "resident", "upstream", lab, t, 1, 64, price, "-", "measured", "U2 warm -M wall (page cache partly warm)")
        else:
            fdb = ph["fetch-db"]["seconds"]
            add(1, "from-scratch", "upstream", lab, boot_of(m) + ph["setup"]["seconds"] + fdb + t, 1, 64, price, "-", "measured",
                "U2 boot+setup+RODA onto NVMe+the cold -M wall (its reads fetch excluded)", f"{fdb:.0f}", f"{HASH_GB / fdb:.1f}")

# Per-axis bests with the attribution, and the kill condition.
best, kills = [], {}
for regime in ("resident", "from-scratch"):
    kills[regime] = True
    for c in (1, 10, 100, 1000):
        sel = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["kind"] not in ("placeholder",)]
        ours = [r for r in sel if r["side"] == "ours"]
        up = [r for r in sel if r["side"] == "upstream"]
        if c == 1000:
            best.append([regime, c, "placeholder only (ours); upstream modelled and infeasible as specified", "-", "-", "-", "-", "-", "-"])
            continue
        if not ours or not up:
            best.append([regime, c, "no data on one side", "-", "-", "-", "-", "-", "-"])
            continue
        ot, ut = min(ours, key=lambda r: r["time_s"]), min(up, key=lambda r: r["time_s"])
        oc, uc = min(ours, key=lambda r: r["usd_per_sample"]), min(up, key=lambda r: r["usd_per_sample"])
        rt, rc = ut["time_s"] / ot["time_s"], uc["usd_per_sample"] / oc["usd_per_sample"]
        wt, et = ot["fleet_vcpus"] / ut["fleet_vcpus"], ot["mpairs_per_s_per_vcpu"] / ut["mpairs_per_s_per_vcpu"]
        pc, ec = uc["usd_per_vcpu_h"] / oc["usd_per_vcpu_h"], oc["mpairs_per_s_per_vcpu"] / uc["mpairs_per_s_per_vcpu"]
        kill = rt < 5 and rc < 5
        kills[regime] = kills[regime] and kill
        refs = []
        if c == 1:
            refs.append(f"time vs ~6-20x: {'below 6x' if rt < 6 else ('6-20x' if rt <= 20 else 'above 20x')}")
        if c >= 100:
            refs.append(f"$ vs ~20x: {'below' if rc < 20 else 'at or above'}")
        pre = sorted({ot["engine_pre_fix"], oc["engine_pre_fix"]})
        st = ""
        if regime == "from-scratch":
            st = (f"; staging ours {ot['staging_s']} s at {ot['staging_GBps']} GB/s, upstream {ut['staging_s']} s at "
                  f"{ut['staging_GBps']} GB/s")
        best.append([regime, c,
                     f"time: ours {ot['point']} {ot['time_s']:.1f} s, upstream {ut['point']} {ut['time_s']:.1f} s",
                     f"{rt:.2f} = width {wt:.2f} (V {ot['fleet_vcpus']} vs {ut['fleet_vcpus']}) x per-vCPU {et:.2f} "
                     f"({1000 * ot['mpairs_per_s_per_vcpu']:.2f} vs {1000 * ut['mpairs_per_s_per_vcpu']:.2f} kpairs/s/vCPU){st}",
                     f"$: ours {oc['point']} ${oc['usd_per_sample']:.5f}, upstream {uc['point']} ${uc['usd_per_sample']:.5f}",
                     f"{rc:.2f} = price/vCPU-h {pc:.2f} (${uc['usd_per_vcpu_h']:.4f} vs ${oc['usd_per_vcpu_h']:.4f}) x per-vCPU "
                     f"{ec:.2f} ({1000 * oc['mpairs_per_s_per_vcpu']:.2f} vs {1000 * uc['mpairs_per_s_per_vcpu']:.2f} kpairs/s/vCPU)",
                     "; ".join(refs) or "-", f"under 5x on both: {'yes' if kill else 'no'}",
                     f"engine pre-fix: {'/'.join(pre)}"])

# Pareto sets per cohort, regime and side.
pareto = []
for c in (1, 10, 100):
    for regime in ("resident", "from-scratch"):
        for side in ("ours", "upstream"):
            sel = [r for r in rows if r["cohort"] == c and r["regime"] == regime and r["side"] == side and r["kind"] == "measured"]
            for r in sel:
                dom = any(o is not r and o["time_s"] <= r["time_s"] and o["usd_per_sample"] <= r["usd_per_sample"]
                          and (o["time_s"] < r["time_s"] or o["usd_per_sample"] < r["usd_per_sample"]) for o in sel)
                if not dom:
                    pareto.append([c, regime, side, r["point"], f"{r['time_s']:.2f}", f"{r['usd_per_sample']:.6f}",
                                   r["fleet_vcpus"], f"{r['usd_per_vcpu_h']:.4f}", f"{r['mpairs_per_s_per_vcpu']:.4f}",
                                   r["engine_pre_fix"]])

os.makedirs(OUT, exist_ok=True)
head = ["cohort", "regime", "side", "point", "time_s", "usd_per_sample_derived", "fleet_vcpus", "usd_per_vcpu_h",
        "mpairs_per_s_per_vcpu", "staging_s", "staging_GBps", "billed_over_derived", "engine_pre_fix", "kind", "basis"]
with open(os.path.join(OUT, "frontier.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(head)
    for r in sorted(rows, key=lambda r: (r["cohort"], r["regime"], r["side"], r["time_s"])):
        w.writerow([r["cohort"], r["regime"], r["side"], r["point"], f"{r['time_s']:.2f}", f"{r['usd_per_sample']:.6f}",
                    r["fleet_vcpus"], f"{r['usd_per_vcpu_h']:.4f}", f"{r['mpairs_per_s_per_vcpu']:.4f}", r["staging_s"],
                    r["staging_GBps"], r["billed_over_derived"], r["engine_pre_fix"], r["kind"], r["basis"]])
ph_ = ["cohort", "regime", "side", "point", "time_s", "usd_per_sample_derived", "fleet_vcpus", "usd_per_vcpu_h",
       "mpairs_per_s_per_vcpu", "engine_pre_fix"]
with open(os.path.join(OUT, "pareto.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(ph_)
    w.writerows(pareto)
gc = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
with open(os.path.join(OUT, "frontier.md"), "w") as fh:
    fh.write("# H-main per-axis bests and Pareto sets (generated by scripts/lib/g3_frontier.py)\n\n")
    fh.write("**Every engine point here is pre-fix (#44) until regenerated.**\n\n")
    fh.write(f"Generated at {gc}. Do not edit: rerun `make g3-frontier`. Every point is in frontier.tsv; the Pareto "
             "sets are in pareto.tsv.\n\n")
    fh.write(__doc__.split("Definitions (generated into frontier.md):")[1].strip().replace("\n  ", "\n") + "\n\n")
    fh.write("## Per-axis bests\n\n")
    hs = ["regime", "cohort", "best time (each side)", "time ratio = width x per-vCPU efficiency", "best $/sample, derived (each side)",
          "$ ratio = price per vCPU-hour x per-vCPU efficiency", "registered reference", "kill check", "provenance"]
    fh.write("| " + " | ".join(hs) + " |\n|" + "---|" * len(hs) + "\n")
    for s in best:
        fh.write("| " + " | ".join(str(x) for x in s) + " |\n")
    for regime, k in kills.items():
        fh.write(f"\nKill condition, {regime} (under 5x on both axes at every measured cohort size 1, 10, 100): "
                 f"{'MET' if k else 'not met'}.\n")
    fh.write("\nE1's cohort-10 from-scratch path includes its three earlier cohort-1 invocations (it ran c10 last), "
             "so it overstates a cohort-10-only run.\n")
    fh.write("\n## Billed / derived (where a run's bill is known)\n\n")
    fh.write("| point | cohort | regime | billed / derived |\n|---|---|---|---|\n")
    for r in rows:
        if r["billed_over_derived"] != "-":
            fh.write(f"| {r['point']} | {r['cohort']} | {r['regime']} | {r['billed_over_derived']} |\n")
    fh.write("\nUpstream's runs (U1, U2) each ran many rungs, so their bills are not separable per rung: not known.\n")
    fh.write("\n## Pareto sets (non-dominated in time and derived $/sample, per side)\n\n")
    fh.write("| " + " | ".join(ph_) + " |\n|" + "---|" * len(ph_) + "\n")
    for p in pareto:
        fh.write("| " + " | ".join(str(x) for x in p) + " |\n")
print(f"g3_frontier: {len(rows)} points, {len(pareto)} Pareto points -> {OUT}/frontier.{{tsv,md}}, pareto.tsv")
