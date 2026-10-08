#!/usr/bin/env python3
"""The G3 campaign's generated tables (#25), from the record only: every cohort dir and single run
under results/g3/ started at or after SINCE (default 2026-10-08T04:00:00Z, after E1).

  g3_campaign.py [SINCE]   -> results/g3/campaign/{points.tsv, spend.tsv, rules.tsv, summary.md}

points.tsv: one row per campaign point that finished (tables/point.tsv of each cohort dir), with
the model's prediction from E1's measured rates next to each measured term (load at 1.80 GB/s
per node; the cohort's LPT wall as the larger of the busiest rank's pairs at the per-node rate
and the largest sample at 1.84 Mpairs/s, the per-stream input rate) and their ratio.
spend.tsv: every run since SINCE (campaign points, failed attempts, staging, U1, U2): cost, state,
orphan result. rules.tsv: the stopping rules of #25 evaluated on points.tsv.
summary.md: the three tables, generated.
"""
import csv, glob, json, os, statistics, sys

SINCE = sys.argv[1] if len(sys.argv) > 1 else "2026-10-08T04:00:00Z"
G = "results/g3"
OUT = os.path.join(G, "campaign")
os.makedirs(OUT, exist_ok=True)
HASH = 1189091671800
B_NODE = 1.80e9          # E1: load GB/s per node (results/g3/20261008-021537-cb0cea7-7e51-n8 rates.tsv)
R_IN = 1.84e6            # E1: per-stream input (decompress + parse) pairs/s (E1 summary.md)
R_CPU = 161638           # E1: pairs per worker CPU-second at cohort 10 (rates.tsv, c10)


def tsv(p):
    return list(csv.DictReader(open(p), delimiter="\t"))


def w(name, head, rows):
    with open(os.path.join(OUT, name), "w", newline="") as fh:
        x = csv.writer(fh, delimiter="\t", lineterminator="\n")
        x.writerow(head)
        x.writerows(rows)


def start_of(d):
    for f in ("cohort.json", "manifest.json"):
        p = os.path.join(d, f)
        if os.path.exists(p):
            j = json.load(open(p))
            return j.get("start", ""), j
    return "", None


points, spend = [], []
for d in sorted(glob.glob(os.path.join(G, "2026*"))):
    if not os.path.isdir(d):
        continue
    st, j = start_of(d)
    if j is None or st.replace("+00:00", "Z") < SINCE:
        continue
    if os.path.exists(os.path.join(d, "cohort.json")):
        # The cohort's cost: the sum of its members' manifests (refinalised members of an
        # interrupted cohort included; cohort.json's own total is null there).
        mc = 0.0
        for m in j.get("members", []):
            mp = os.path.join(G, m["run_id"], "manifest.json")
            if os.path.exists(mp):
                mc += float(json.load(open(mp)).get("cost_usd") or 0)
        spend.append([os.path.basename(d), j.get("spec"), j.get("instance_type"), j.get("nodes"), f"{mc:.4f}",
                      j.get("ended"), j.get("orphans_rc")])
        pp = os.path.join(d, "tables", "point.tsv")
        if os.path.exists(pp):
            p = tsv(pp)[0]
            p["spec"] = j.get("spec")
            p["dir"] = d
            points.append(p)
    elif not os.path.basename(d).split("-")[-1].startswith("r") or "-n" not in os.path.basename(d):
        # A single run (U1, U2, staging before the cohort mode); members of cohorts are counted in their cohort.
        if "-n" in os.path.basename(d) and os.path.basename(d).rsplit("-", 1)[-1].startswith("r"):
            continue
        orc = (j.get("orphan_check") or {}).get("rc") if isinstance(j.get("orphan_check"), dict) else j.get("orphan_check")
        spend.append([os.path.basename(d), j.get("spec"), (j.get("instance") or {}).get("type"), 1, f"{j.get('cost_usd') or 0:.4f}",
                      (j.get("instance") or {}).get("final_state"), orc])

DEF = {}
dp = os.path.join("scripts", "lib", "g3_defects.tsv")
if os.path.exists(dp):
    for r in tsv(dp):
        DEF[r["run"]] = r
for r in spend:
    dd = DEF.get(r[0])
    r += [dd["class"] if dd else "ok", dd["evidence"] if dd else ""]

rows = []
for p in points:
    N, C = int(p["N"]), int(p["cohort"])
    plan = tsv(os.path.join(p["dir"] + "-r0", "out", "rank0", "placement.tsv"))
    lpt = [x for x in plan if x["batch"] == "0"]
    loads = {}
    for x in lpt:
        loads[x["home"]] = loads.get(x["home"], 0) + int(x["weight"])
    nproc = None
    for l in open(os.path.join(p["dir"] + "-r0", "log", "run.log"), errors="replace"):
        if " nproc " in l and "built " in l:
            nproc = int(l.split(" nproc ")[1].split(";")[0])
            break
    pairs_total = sum(int(x["weight"]) for x in lpt)
    rate_vcpu = pairs_total / float(p["lpt_wall_s"]) / (N * nproc) if nproc else float("nan")
    load_pred = HASH / N / B_NODE
    r = dict(p)
    r.update({"load_pred_s": f"{load_pred:.1f}", "load_meas_over_pred": f"{float(p['load_s']) / load_pred:.2f}",
              "mod_over_lpt": f"{float(p['mod_wall_s']) / float(p['lpt_wall_s']):.3f}" if p["mod_wall_s"] not in ("-", "") else "-",
              "busiest_rank_Mpairs": f"{max(loads.values()) / 1e6:.1f}",
              "largest_sample_input_floor_s": f"{max(int(x['weight']) for x in lpt) / R_IN:.1f}",
              "vcpus_per_node": nproc, "fleet_vcpus": N * nproc if nproc else "-", "lpt_pairs_per_vcpu_s": f"{rate_vcpu:.0f}",
              "lpt_rate_over_e1_worker_cpu_rate": f"{rate_vcpu / R_CPU:.2f}"})
    rows.append(r)
head = ["spec", "type", "N", "cohort", "inflight", "threads", "vcpus_per_node", "fleet_vcpus", "price_per_h", "cost_usd_members",
        "boot_s", "setup_s", "manifest_s", "fetch_s", "load_s", "load_pred_s", "load_meas_over_pred", "rendezvous_s_max",
        "lpt_wall_s", "lpt_repeat_wall_s", "lpt_spread", "mod_wall_s", "mod_over_lpt", "placement_order_lever",
        "busiest_rank_Mpairs", "largest_sample_input_floor_s", "lpt_pairs_per_vcpu_s", "lpt_rate_over_e1_worker_cpu_rate",
        "c1_striped_wall_s_median", "c1_home_wall_s_median", "derived_T_s", "observed_T_s", "skew_rendezvous_s",
        "body_tail_s", "harness_tail_s_max", "harness_tail_s_median", "harness_tail_s_top3", "T_engine_s", "T_with_harness_s",
        "derived_usd_per_sample_engine", "derived_usd_per_sample_with_harness", "measured_usd_per_sample_whole_run"]
w("points.tsv", head, [[r.get(h, "-") for h in head] for r in rows])
w("spend.tsv", ["run", "spec", "type", "nodes", "cost_usd", "ended_or_state", "orphans_rc", "outcome", "evidence"], spend)

# Stopping rules (#25), each T-based rule evaluated both ways: T_engine (observed critical path +
# the body tail) and T_with_harness (+ the harness's body-end -> terminate tail).
rules = []
e2 = sorted([r for r in rows if "-e2-" in r["spec"]], key=lambda r: int(r["N"]))
for col in ("T_engine_s", "T_with_harness_s"):
    for a, b in zip(e2, e2[1:]):
        ta, tb = float(a[col]), float(b[col])
        sp = max(float(a["lpt_spread"]) * float(a["lpt_wall_s"]), float(b["lpt_spread"]) * float(b["lpt_wall_s"]))
        rules.append(["extend N while T(N) improves by more than 2x the within-run spread", f"E2 N {a['N']} -> {b['N']} ({col})",
                      f"T {ta:.0f} -> {tb:.0f} s; improvement {ta - tb:.0f} s; 2 x spread {2 * sp:.1f} s; fleet vCPUs "
                      f"{a['fleet_vcpus']} -> {b['fleet_vcpus']} (E2's fleets are memory-equal, not vCPU-equal)",
                      "improves" if ta - tb > 2 * sp else "does not improve"])
for r in rows:
    if "-e3-c8g" in r["spec"]:
        t1 = sum(float(r[k]) for k in ("boot_s", "setup_s", "fetch_s", "load_s", "c1_striped_wall_s_median", "body_tail_s"))
        rules.append(["c8gn only if load > 50% of the cohort-1 wall", f"E3 {r['type']} N={r['N']}",
                      f"load {float(r['load_s']):.0f} s of cohort-1 wall {t1:.0f} s (boot+setup+fetch+load+c1 striped+body tail) = "
                      f"{100 * float(r['load_s']) / t1:.0f}%", "run c8gn" if float(r["load_s"]) > 0.5 * t1 else "skip c8gn"])
c8 = {int(r["N"]): r for r in rows if "-c8g." in r["spec"]}
if 16 in c8 and 32 in c8:
    for col in ("T_engine_s", "T_with_harness_s"):
        rules.append(["N=64 only if N=32 beats N=16 (c8g)", f"E3/E4 c8g ({col})", f"T(16) {c8[16][col]} s, T(32) {c8[32][col]} s",
                      "run N=64" if float(c8[32][col]) < float(c8[16][col]) else "skip N=64"])
for r in rows:
    if r["placement_order_lever"] == "unresolved":
        rules.append(["placement + order lever (j mod N vs LPT) resolved only if its gain exceeds 2 x the within-run spread",
                      f"{r['spec']}", f"mod/LPT {r['mod_over_lpt']}, spread {r['lpt_spread']}", "unresolved"])
w("rules.tsv", ["rule", "where", "measured", "outcome"], rules)

# U2 against the engine's single sample (sample 1, SRR5935740), two labelled pairs.
u2 = []
for d in sorted(glob.glob(os.path.join(G, "2026*"))):
    mp = os.path.join(d, "manifest.json")
    jl = os.path.join(d, "out", "g2-u2", "runs.jsonl")
    if not (os.path.exists(mp) and os.path.exists(jl)):
        continue
    m = json.load(open(mp))
    ph = {x["phase"]: x for x in m.get("phases", [])}
    rr = [json.loads(l) for l in open(jl) if l.strip()]
    s1 = [x for x in rr if "SRR5935740" in json.dumps(x.get("input", "")) or "SRR5935740" in x.get("rung", "")]
    warm = [x for x in s1 if x.get("state") == "warm"]
    cold = [x for x in s1 if x.get("state") == "cold"]
    boot = (ts_ := None)
    launch = m["instance"]["launch_time"]
    body = ph.get("body", {}).get("start")
    import datetime as dt
    t = lambda x: dt.datetime.fromisoformat(x.replace("Z", "+00:00"))
    boot_s = (t(body) - t(launch)).total_seconds() if body else float("nan")
    setup_s = ph.get("setup", {}).get("seconds", float("nan"))
    stage_s = ph.get("fetch-db", {}).get("seconds", float("nan"))  # RODA onto NVMe; fetch-reads (other inputs too) excluded
    for r in rows:
        if "-e2-" not in r["spec"] and "-e3-" not in r["spec"]:
            continue
        c1 = float(r["c1_home_wall_s_median"])
        if warm:
            u2.append(["resident (table already in memory or page cache)", r["spec"], f"{c1:.2f}", "c1 home wall",
                       f"{warm[0]['classify_s']:.2f} / {warm[0]['wall_s']:.2f}", "U2 warm classify / wall", os.path.basename(d)])
        if cold:
            ours = sum(float(r[k]) for k in ("boot_s", "setup_s", "fetch_s", "load_s")) + c1
            best = min(cold, key=lambda x: x["wall_s"])
            u2.append(["from scratch (boot, setup and staging, then the sample cold)", r["spec"],
                       f"{ours:.0f}", "boot+setup+fetch+load+c1 home (the fetch is the point's whole fetch: conservative)",
                       f"{boot_s + setup_s + stage_s + best['wall_s']:.0f}", f"U2 boot {boot_s:.0f} + setup {setup_s:.0f} + RODA staging "
                       f"onto NVMe {stage_s:.0f} + cold wall {best['wall_s']:.1f} (T={best.get('threads')}); its reads fetch excluded",
                       os.path.basename(d)])
w("u2-pairs.tsv", ["pair", "engine_point", "engine_s", "engine_basis", "upstream_s", "upstream_basis", "u2_run"], u2)

total = sum(float(s_[4]) for s_ in spend)
defect = sum(float(s_[4]) for s_ in spend if s_[7].startswith("defect"))
with open(os.path.join(OUT, "summary.md"), "w") as fh:
    fh.write(f"# G3 campaign tables (generated by scripts/lib/g3_campaign.py; runs since {SINCE})\n\n")
    fh.write(f"Spend since {SINCE}: ${total:.2f} over {len(spend)} runs, of which ${defect:.2f} on attempts lost to defects "
             f"(spend.tsv outcome; scripts/lib/g3_defects.tsv). Points: {len(rows)} (points.tsv).\n\n")
    fh.write("**T, defined** (docs/cohort.md, \"The G3 campaign\"): derived_T = max boot + max setup + max manifest + max fetch + "
             "max load + LPT wall (per-term maxima over ranks, so not any one rank's path); observed_T = first launch to the last "
             "rank's end of batch 0 (the measured critical path); skew_rendezvous = observed - derived; T_engine = observed + body "
             "tail (invocation end to body end); T_with_harness = T_engine + harness tail (body end to terminated). "
             "derived $/sample = N x price x T / cohort; measured $/sample = summed member cost / cohort (the whole run, every "
             "batch).\n\n")
    fh.write("E2's fleets are memory-equal, not vCPU-equal (fleet_vcpus); the knee is read with that next to it (rules.tsv).\n\n")
    fh.write("Predictions use E1's measured rates: load 1.80 GB/s per node; input 1.84 Mpairs/s per stream; worker rate 161,638 "
             "pairs per worker CPU-second (E1 c10; the cohort LPT rate here is per vCPU of wall time, so the ratio also carries "
             "idle and non-worker time).\n\n")
    for name in ("points.tsv", "rules.tsv", "u2-pairs.tsv", "law1-u2.tsv", "spend.tsv"):
        if not os.path.exists(os.path.join(OUT, name)):
            continue
        t = list(csv.reader(open(os.path.join(OUT, name)), delimiter="\t"))
        fh.write(f"## {name}\n\n| " + " | ".join(t[0]) + " |\n|" + "---|" * len(t[0]) + "\n")
        for r in t[1:]:
            fh.write("| " + " | ".join(str(x) for x in r) + " |\n")
        fh.write("\n")
print(f"g3_campaign: {len(rows)} points, {len(spend)} runs, ${total:.2f} (${defect:.2f} on defect attempts) -> {OUT}/")
