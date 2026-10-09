#!/usr/bin/env python3
"""H-main frontier table (#25): ours against upstream at its best, per cohort size and regime,
from the record only.

  g3_frontier.py   -> results/g3/campaign/frontier.{tsv,md}

Inputs: results/g3/campaign/points.tsv (E2-E4, from g3_campaign.py), the E1 cohort (cohort 10),
U1 (results/g3/*/out/u1.jsonl with tables/rungs.tsv, prep.tsv), U2 (out/g2-u2/summary.tsv),
each run's manifest (phases, launch time, truffle price), results/cohort/PRJNA398089/runs.tsv.

Definitions (generated into frontier.md):
  - Regimes. resident: the table is already in memory (ours: the in-run batch walls after the
    load; upstream: U1's passes on a tmpfs-resident table, U2's warm rung). from-scratch: from
    instance launch (boot + setup + the table's staging or load + the input fetch + the pass).
  - Upstream's fq passes have their fq preparation added back (U1's pre-decompression, timed per
    sample in prep.tsv; per sample its fastest preparation). Input sha256 verification is inside
    both sides' fetch phases; U1's ETag computation is outside its timed walls; ours computes none.
  - Time: measured wall seconds. $/sample: on-demand price x nodes x that measured time /
    cohort ("price x measured time"); for ours the whole-run billed cost / cohort is shown beside
    it (it covers every batch of the run, so it overstates the cohort's share).
  - Best per axis: the minimum time and, separately, the minimum $/sample over each side's points.
  - Ratios: upstream / ours per axis (> 1: ours is better). Registered reference points (#25
    H-main): ~20x lower $/sample at cohort >= 100; ~6x (Tier A) to 20x faster for a single sample.
    Kill condition: under 5x on both axes at every cohort size. Evaluated per regime.
  - Cohort 1000 is modelled from cohort 100 by the pairs ratio of the first 1000 to the first 100
    samples (runs.tsv), for both sides, and flagged.
  - Every engine point is marked pre-fix where its engine predates the #44 fix (904c2a5).
"""
import csv, datetime as dt, glob, json, os, statistics, subprocess

G = "results/g3"
OUT = os.path.join(G, "campaign")


def tsv(p):
    return list(csv.DictReader(open(p), delimiter="\t"))


def ts(x):
    return dt.datetime.fromisoformat(x.replace("Z", "+00:00"))


def phases(m):
    return {p["phase"]: p for p in m.get("phases", [])}


def boot_of(m):
    ph = phases(m)
    return (ts(ph["body"]["start"]) - ts(m["instance"]["launch_time"])).total_seconds()


def prefix(commit):
    rc = subprocess.run(["git", "merge-base", "--is-ancestor", "904c2a5", commit], capture_output=True).returncode
    return "yes" if rc == 1 else ("no" if rc == 0 else "unknown")


runs = tsv("results/cohort/PRJNA398089/runs.tsv")
pairs = lambda c: sum(int(r["read_count"]) for r in runs if int(r["rank"]) <= c)
R1000 = pairs(1000) / pairs(100)

rows = []  # cohort, regime, side, point, time_s, usd_per_sample (price x time), usd_whole_run, pre_fix, modelled, basis


def add(c, regime, side, point, t, usd, whole, pre, modelled, basis):
    rows.append({"cohort": c, "regime": regime, "side": side, "point": point, "time_s": t, "usd_per_sample": usd,
                 "usd_per_sample_whole_run": whole, "engine_pre_fix": pre, "modelled": modelled, "basis": basis})


# Ours: E2-E4 (cohort 100 and the single-sample batches).
for p in tsv(os.path.join(OUT, "points.tsv")):
    N, price = int(p["N"]), float(p["price_per_h"])
    pre, name = p["engine_pre_fix"], f"{p['type']} N={N}"
    fixed = sum(float(p[k]) for k in ("boot_s", "setup_s", "manifest_s", "fetch_s", "load_s"))
    c1 = min(float(x) for x in (p["c1_home_wall_s_median"], p["c1_striped_wall_s_median"]) if x not in ("-", ""))
    lpt = float(p["lpt_wall_s"])
    whole = float(p["measured_usd_per_sample_whole_run"])
    add(1, "resident", "ours", name, c1, N * price * c1 / 3600, "-", pre, "no", "the sample on its home node or striped, table loaded")
    add(1, "from-scratch", "ours", name, fixed + c1, N * price * (fixed + c1) / 3600, "-", pre, "no",
        "boot+setup+manifest+fetch (the point's whole fetch)+load+c1")
    add(100, "resident", "ours", name, lpt, N * price * lpt / 3600 / 100, "-", pre, "no", "the LPT batch wall, table loaded")
    te = float(p["T_engine_s"])
    add(100, "from-scratch", "ours", name, te, N * price * te / 3600 / 100, f"{whole:.5f}", pre, "no",
        "observed critical path (first launch to the last rank's end of batch 0) + body tail")
    add(1000, "resident", "ours", name, lpt * R1000, N * price * lpt * R1000 / 3600 / 1000, "-", pre, "yes",
        f"cohort-100 LPT wall x pairs ratio {R1000:.2f}")
    t1k = te - lpt + lpt * R1000 + float(p["fetch_s"]) * (R1000 - 1)
    add(1000, "from-scratch", "ours", name, t1k, N * price * t1k / 3600 / 1000, "-", pre, "yes",
        f"cohort-100 T_engine with the LPT wall and the fetch scaled by {R1000:.2f}")

# Ours at cohort 10: E1 (8 x x8g.4xlarge; its c10 batches 0 and 1: SDK, parallel, in flight 1 and 2).
for cj in glob.glob(os.path.join(G, "*", "cohort.json")):
    c = json.load(open(cj))
    if c.get("spec") != "runs/g3-e1.json" or not os.path.exists(os.path.join(os.path.dirname(cj), "tables", "batches.tsv")):
        continue
    d = os.path.dirname(cj)
    b = [x for x in tsv(os.path.join(d, "tables", "batches.tsv")) if x["batch"] in ("0", "1")]
    m0 = json.load(open(os.path.join(G, c["members"][0]["run_id"], "manifest.json")))
    price, N = float(m0["truffle_price_usd_per_hour"]), int(c["nodes"])
    wall = min(float(x["wall_s"]) for x in b)
    pre = prefix(c["commit"])
    add(10, "resident", "ours", f"E1 {c['instance_type']} N={N}", wall, N * price * wall / 3600 / 10, "-", pre, "no",
        "E1 c10 batch 0 or 1 wall (parallel j mod N, SDK), table loaded")
    ph = phases(m0)
    load = max(float(r["value"]) for r in tsv(os.path.join(d, "tables", "tidy.tsv"))
               if r["invocation"] == "c10" and r["kind"] == "phase" and r["metric"].startswith("shard-load-") and not r["metric"].endswith(".start_s"))
    fs = boot_of(m0) + ph["setup"]["seconds"] + ph["fetch"]["seconds"] + load + wall
    add(10, "from-scratch", "ours", f"E1 {c['instance_type']} N={N}", fs, N * price * fs / 3600 / 10, "-", pre, "no",
        "rank 0's boot+setup+fetch (all 10 samples)+the c10 load+the batch wall")

# Upstream: U1 (resident tmpfs, x8g.24xlarge) and U2 (NVMe, r8gd.16xlarge).
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
    order = [r["run"] for r in runs]
    for r in tsv(os.path.join(d, "tables", "rungs.tsv")):
        if r["basis"] != "measured" or "(n=" in r["rung"] and False:
            pass
        c = int(r["cohort"])
        if r["rung"].startswith("ref") or (r["rung"].startswith("A-c1") and "(n=" not in r["rung"]):
            continue  # A rungs enter through their n=3 medians
        t = float(r["pass_wall_s"])
        if r["input"] == "fq":
            t += sum(prep.get(s, 0) for s in order[:c])
        mod = "yes" if r["basis"] != "measured" else "no"
        label = f"U1 {r['rung']}" + (" (+fq prep)" if r["input"] == "fq" else "")
        add(c, "resident", "upstream", label, t, price * t / 3600 / c, "-", "-", mod, "U1 pass on the tmpfs-resident table")
        add(c, "from-scratch", "upstream", label, stage + t, price * (stage + t) / 3600 / c, "-", "-", mod,
            "U1 boot+setup+RODA onto tmpfs+the input fetch+the pass")
        if c == 100 and mod == "no":
            add(1000, "resident", "upstream", label, t * R1000, price * t * R1000 / 3600 / 1000, "-", "-", "yes",
                f"cohort-100 pass x pairs ratio {R1000:.2f}")
            t1k = stage + ph["fetch-inputs"]["seconds"] * (R1000 - 1) + t * R1000
            add(1000, "from-scratch", "upstream", label, t1k, price * t1k / 3600 / 1000, "-", "-", "yes",
                f"cohort-100 from-scratch with the pass and the input fetch scaled by {R1000:.2f}")
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
            add(1, "resident", "upstream", lab, t, price * t / 3600, "-", "-", "no", "U2 warm -M wall (page cache partly warm)")
        else:
            fs = boot_of(m) + ph["setup"]["seconds"] + ph["fetch-db"]["seconds"] + t
            add(1, "from-scratch", "upstream", lab, fs, price * fs / 3600, "-", "-", "no",
                "U2 boot+setup+RODA onto NVMe+the cold -M wall (its reads fetch excluded)")

# Best per axis, ratios, references and the kill condition.
out = []
summary = []
for regime in ("resident", "from-scratch"):
    kill_all = True
    for c in (1, 10, 100, 1000):
        sel = [r for r in rows if r["cohort"] == c and r["regime"] == regime]
        ours = [r for r in sel if r["side"] == "ours"]
        up = [r for r in sel if r["side"] == "upstream"]
        if not ours or not up:
            summary.append([regime, c, "-", "-", "-", "-", "-", "-", "no data on one side", "-"])
            continue
        ot, ut = min(ours, key=lambda r: r["time_s"]), min(up, key=lambda r: r["time_s"])
        oc, uc = min(ours, key=lambda r: r["usd_per_sample"]), min(up, key=lambda r: r["usd_per_sample"])
        rt, rc = ut["time_s"] / ot["time_s"], uc["usd_per_sample"] / oc["usd_per_sample"]
        kill = rt < 5 and rc < 5
        kill_all = kill_all and kill
        refs = []
        if c == 1:
            refs.append(f"time ratio {rt:.1f}x vs registered ~6x (Tier A) to 20x: "
                        f"{'below 6x' if rt < 6 else ('6-20x' if rt <= 20 else 'above 20x')}")
        if c >= 100:
            refs.append(f"$/sample ratio {rc:.1f}x vs registered ~20x: {'below' if rc < 20 else 'at or above'}")
        mod = "yes" if "yes" in (ot["modelled"], ut["modelled"], oc["modelled"], uc["modelled"]) else "no"
        pre = "yes" if "yes" in (ot["engine_pre_fix"], oc["engine_pre_fix"]) else "no"
        summary.append([regime, c, f"{ot['point']} {ot['time_s']:.1f} s", f"{ut['point']} {ut['time_s']:.1f} s", f"{rt:.2f}",
                        f"{oc['point']} ${oc['usd_per_sample']:.5f}", f"{uc['point']} ${uc['usd_per_sample']:.5f}", f"{rc:.2f}",
                        "; ".join(refs) or "-", f"under 5x on both: {'yes' if kill else 'no'}; modelled: {mod}; engine pre-fix: {pre}"])
    summary.append([regime, "all", "-", "-", "-", "-", "-", "-", "-",
                    f"kill condition (under 5x on both axes at every cohort size): {'MET' if kill_all else 'not met'}"])

os.makedirs(OUT, exist_ok=True)
head = ["cohort", "regime", "side", "point", "time_s", "usd_per_sample", "usd_per_sample_whole_run", "engine_pre_fix", "modelled", "basis"]
with open(os.path.join(OUT, "frontier.tsv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(head)
    for r in sorted(rows, key=lambda r: (r["cohort"], r["regime"], r["side"], r["time_s"])):
        w.writerow([r["cohort"], r["regime"], r["side"], r["point"], f"{r['time_s']:.2f}", f"{r['usd_per_sample']:.6f}",
                    r["usd_per_sample_whole_run"], r["engine_pre_fix"], r["modelled"], r["basis"]])
gc = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
with open(os.path.join(OUT, "frontier.md"), "w") as fh:
    fh.write("# H-main frontier (generated by scripts/lib/g3_frontier.py)\n\n")
    fh.write(f"Generated at {gc}. Do not edit: rerun `make g3-frontier`. Every point is in frontier.tsv.\n\n")
    fh.write(__doc__.split("Definitions (generated into frontier.md):")[1].strip().replace("\n  ", "\n") + "\n\n")
    hs = ["regime", "cohort", "ours: best time", "upstream: best time", "time ratio", "ours: best $/sample",
          "upstream: best $/sample", "$ ratio", "registered reference", "evaluation"]
    fh.write("| " + " | ".join(hs) + " |\n|" + "---|" * len(hs) + "\n")
    for s in summary:
        fh.write("| " + " | ".join(str(x) for x in s) + " |\n")
print(f"g3_frontier: {len(rows)} points -> {OUT}/frontier.{{tsv,md}}")
