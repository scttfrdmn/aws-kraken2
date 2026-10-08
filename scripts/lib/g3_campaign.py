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

rows = []
for p in points:
    N, C = int(p["N"]), int(p["cohort"])
    vcpu = None
    man = json.load(open(glob.glob(os.path.join(p["dir"] + "-r0", "manifest.json"))[0]))
    plan = tsv(glob.glob(os.path.join(p["dir"] + "-r0", "out", "rank0", "placement.tsv"))[0])
    lpt = [x for x in plan if x["batch"] == "0"]
    loads = {}
    for x in lpt:
        loads[x["home"]] = loads.get(x["home"], 0) + int(x["weight"])
    busiest, largest = max(loads.values()), max(int(x["weight"]) for x in lpt)
    vcpu = None
    for k in ("vcpus", "vcpu"):
        vcpu = vcpu or (man.get("instance") or {}).get(k)
    load_pred = HASH / N / B_NODE
    rows.append([p["spec"], p["type"], N, C, p["price_per_h"], p["cost_usd"], p["boot_s"], p["setup_s"], p["fetch_s"],
                 p["load_s"], f"{load_pred:.1f}", f"{float(p['load_s']) / load_pred:.2f}",
                 p["lpt_wall_s"], p["lpt_repeat_wall_s"], p["lpt_spread"], p["mod_wall_s"],
                 f"{float(p['mod_wall_s']) / float(p['lpt_wall_s']):.3f}" if p["mod_wall_s"] not in ("-", "") else "-",
                 f"{busiest / 1e6:.1f}", f"{largest / R_IN:.1f}",
                 p["c1_striped_wall_s_median"], p["c1_home_wall_s_median"], p["tail_s"], p["derived_cohort_T_s"],
                 p["derived_cohort_cost_usd"], p["derived_usd_per_sample"]])
head = ["spec", "type", "N", "cohort", "price_per_h", "cost_usd", "boot_s", "setup_s", "fetch_s", "load_s", "load_pred_s",
        "load_meas_over_pred", "lpt_wall_s", "lpt_repeat_wall_s", "lpt_spread", "mod_wall_s", "mod_over_lpt",
        "busiest_rank_Mpairs", "largest_sample_input_floor_s", "c1_striped_s", "c1_home_s", "tail_s", "derived_cohort_T_s",
        "derived_cohort_cost_usd", "derived_usd_per_sample"]
w("points.tsv", head, rows)
w("spend.tsv", ["run", "spec", "type", "nodes", "cost_usd", "ended_or_state", "orphans_rc"], spend)

# Stopping rules (#25).
rules = []
e2 = sorted([r for r in rows if "-e2-" in r[0]], key=lambda r: r[2])
for a, b in zip(e2, e2[1:]):
    ta, tb = float(a[22]), float(b[22])
    sp = max(float(a[14]) * float(a[12]), float(b[14]) * float(b[12]))
    rules.append(["extend N while T(N) improves by more than 2x the within-run spread", f"E2 N {a[2]} -> {b[2]}",
                  f"T {ta:.0f} -> {tb:.0f} s; improvement {ta - tb:.0f} s; 2 x spread {2 * sp:.1f} s",
                  "improves" if ta - tb > 2 * sp else "does not improve"])
for r in rows:
    if "-e3-c8g" in r[0]:
        t1 = float(r[6]) + float(r[7]) + float(r[8]) + float(r[9]) + float(r[19]) + float(r[21])
        rules.append(["c8gn only if load > 50% of the cohort-1 wall", f"E3 {r[1]} N={r[2]}",
                      f"load {float(r[9]):.0f} s of cohort-1 wall {t1:.0f} s (boot+setup+fetch+load+c1 striped+tail) = {100 * float(r[9]) / t1:.0f}%",
                      "run c8gn" if float(r[9]) > 0.5 * t1 else "skip c8gn"])
c8 = {r[2]: r for r in rows if "-c8g." in r[0]}
if 16 in c8 and 32 in c8:
    rules.append(["N=64 only if N=32 beats N=16 (c8g)", "E3/E4 c8g", f"T(16) {c8[16][22]} s, T(32) {c8[32][22]} s",
                  "run N=64" if float(c8[32][22]) < float(c8[16][22]) else "skip N=64"])
w("rules.tsv", ["rule", "where", "measured", "outcome"], rules)

total = sum(float(s[4]) for s in spend)
with open(os.path.join(OUT, "summary.md"), "w") as fh:
    fh.write(f"# G3 campaign tables (generated by scripts/lib/g3_campaign.py; runs since {SINCE})\n\n")
    fh.write(f"Spend since {SINCE}: ${total:.2f} over {len(spend)} runs (spend.tsv). Points: {len(rows)} (points.tsv).\n\n")
    fh.write("Predictions use E1's measured rates: load 1.80 GB/s per node; input 1.84 Mpairs/s per stream.\n\n")
    for name in ("points.tsv", "rules.tsv", "spend.tsv"):
        t = list(csv.reader(open(os.path.join(OUT, name)), delimiter="\t"))
        fh.write(f"## {name}\n\n| " + " | ".join(t[0]) + " |\n|" + "---|" * len(t[0]) + "\n")
        for r in t[1:]:
            fh.write("| " + " | ".join(str(x) for x in r) + " |\n")
        fh.write("\n")
print(f"g3_campaign: {len(rows)} points, {len(spend)} runs, ${total:.2f} -> {OUT}/")
