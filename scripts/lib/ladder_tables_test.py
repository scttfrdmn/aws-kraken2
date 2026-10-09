#!/usr/bin/env python3
"""make test: scripts/lib/ladder_tables.py on a synthetic ladder record (synthetic data is for unit
tests only; CLAUDE.md Law 3). Every expected value is worked by hand in the comments below.

The base record: one accession (SRR1) at cohort 1; rungs S0-T1 -> S0-Tv (threads) -> S1 (s5cmd)
-> S2 (rapidgzip) -> O0 -> O1, n = 2 each. Price 3.6 $/h, so billed $ = wall s / 1000 and the
billed granularity is 3.6 x 2 / 3600 = 0.002 $ per node. Walls (s), median, range:
  S0-T1 1000, 1010 -> 1005, 10      S0-Tv 600, 620 -> 610, 20     S1 560, 600 -> 580, 40
  S2    400, 410   -> 405, 10       O0    300, 302 -> 301, 2      O1 200 (a 2-node cohort), 204 -> 202, 4
Wall deltas, threshold 2 x max(range, range, q = 2 s): S0-Tv -395 (40: resolved); S1 -30 (80:
UNRESOLVABLE; predicted -50 is below 80 too); S2 -175 (80); O0 -104 (20); O1 -99 (8): resolved.
S1's own phase (run:fetch-db, one entry, q 1 s): S0-Tv 300, 310; S1 100, 102: delta -204,
threshold 2 x max(2, 10, 1) = 20: resolved, though its wall delta is not.
O0's own phase (run:classify): S2 50, 50 and O0 50, 50: delta 0, spread 0, q 1: below instrument
granularity.
Endpoints: S2 declares S*-time;S*-cost (every cohort), O1 declares c1:O*-time;c1:O*-cost. One cold
S*-time endpoint run (S2, 420 s) and one warm (380 s). So:
  S vs O* (wall, S0-T1 -> O1): -803 = -395 - 30 - 175 - 104 - 99, both totals ladder medians:
    residual 0, an identity.
  S vs S* (wall, S0-T1 -> S2): the total comes from the endpoint run: 420 - 1005 = -585 (n 1:
    unresolvable); the lever deltas sum to -600; residual +15.
  S vs S* (billed, cost endpoint, no endpoint run): -0.600 = -0.395 - 0.030 - 0.175, residual 0.
Utilisation (fleet row): U_cpu 0.5, U_mem_mean 0.25, U_net_baseline 0.1, U_net_rx_baseline 0.06,
U_net_tx_peak 0.02. The fleet cost_usd is the numerator: S0-T1 rep 1's is 0.9 (its billed is 1.0),
so eff_cpu = 0.9 / 0.5 = 1.8. S1 rep 2 has no util.tsv; S0-Tv rep 2's has only a node row: both
missing, never imputed.
"""
import csv
import datetime as dt
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ladder_tables as lt  # noqa: E402

FAIL = []
SHA_OUT, SHA_REP, SHA_BAD = "a" * 64, "b" * 64, "c" * 64
T0 = 1_800_000_000


def check(what, got, want, tol=1e-6):
    if isinstance(want, (int, float)) and not isinstance(want, bool):
        try:
            ok = abs(float(got) - want) <= tol
        except (TypeError, ValueError):
            ok = False
    else:
        ok = got == want
    print(f"ladder_tables_test: {'ok  ' if ok else 'FAIL'} {what}: got {got!r}, want {want!r}")
    if not ok:
        FAIL.append(what)


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat()


LEVERS = """# synthetic lever table
rung\tarm\tpredecessor\tlever\tcounterpart\tphase\tendpoint\tpred_wall_s
S0-T1\tS\t-\tstock\tO0\trun:classify\t\t
S0-Tv\tS\tS0-T1\tthreads\tO0\trun:classify\t\t
S1\tS\tS0-Tv\ts5cmd-staging\tO0b\trun:fetch-db\t\t-50
S2\tS\tS1\trapidgzip\tO0\trun:classify\tS*-time;S*-cost\t
O0\tO\tS2\tplain-path\t-\trun:classify\t\t
O1\tO\tO0\tshards\t-\tsample:classify\tc1:O*-time;c1:O*-cost\t
"""
GOOD = {"output": {"bytes": 10, "sha256": SHA_OUT}, "report": {"bytes": 5, "sha256": SHA_REP}}
BAD = {"output": {"bytes": 9, "sha256": SHA_BAD}, "report": {"bytes": 5, "sha256": SHA_REP}}


def sample(arm, rung, outputs=None, s5="n/a", fallback=None, classify=10.0, acc="SRR1", rc=0, cohort=1):
    s5o = {"status": s5, "P": 16, "nproc": 192}
    if fallback:
        s5o["fallback"] = fallback
    return {"v": 1, "arm": arm, "rung": rung, "cohort": cohort, "accession": acc, "idx": 0, "pairs": 1000, "rc": rc,
            "phases": {"classify": classify}, "s5": s5o, "outputs": outputs or GOOD}


UTIL_HEAD = ["scope", "node", "phase", "U_cpu", "U_mem_mean", "U_mem_peak", "U_net_baseline", "U_net_peak",
             "U_net_rx_baseline", "U_net_rx_peak", "U_net_tx_baseline", "U_net_tx_peak", "cost_usd", "coverage"]


def util(d, cost, fleet=True):
    os.makedirs(os.path.join(d, "tables"), exist_ok=True)
    with open(os.path.join(d, "tables", "util.tsv"), "w") as f:
        f.write("\t".join(UTIL_HEAD) + "\n")
        f.write("\t".join(["node", "x", "(billed window)"] + ["0.9"] * 9 + [f"{cost:.6f}", "full"]) + "\n")
        if fleet:
            f.write("\t".join(["fleet", "1 of 1", "(billed window)", "0.5", "0.25", "0.4", "0.1", "0.05", "0.06", "0.03",
                               "0.04", "0.02", f"{cost:.6f}", "full"]) + "\n")


def manifest(d, rid, params, launch, term, phases, cost=None, put_params=True, accessions=("SRR1",), ref=None):
    os.makedirs(os.path.join(d, "out"), exist_ok=True)
    os.makedirs(os.path.join(d, "log"), exist_ok=True)
    inst = {"type": "x.test", "az": "us-west-2a", "launch_time": iso(launch)}
    if term is not None:
        inst["terminated_at"] = iso(term)
    m = {"gate": "g3", "run_id": rid, "commit": "f" * 40, "region": "us-west-2", "truffle_price_usd_per_hour": 3.6,
         "instance": inst, "start": iso(launch), "stop": iso(launch + 9),
         "cost_usd": cost if cost is not None else ((term or launch) - launch) / 1000.0,
         "phases": [{"phase": k, "seconds": v} for k, v in phases.items()], "sample_accessions": list(accessions)}
    if ref:
        m["sample_accessions"] = []
        m["sample_accessions_ref"] = {"ref": ref, "runs_tsv": "results/cohort/PRJTEST/runs.tsv"}
    if put_params:
        m["params"] = params
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(m, f)


def lines(d, samples):
    with open(os.path.join(d, "out", "lad-samples.jsonl"), "w") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")
    with open(os.path.join(d, "log", "run.log"), "w") as f:
        f.write("[c1] preamble: $- = hB\n")
        for s in samples:
            f.write("[c1] lad-sample " + json.dumps(s) + "\n")


def single(res, rid, arm, rung, rep, wall, phases=None, samples=None, util_cost=None, util_mode="fleet", start=0,
           accessions=("SRR1",), ref=None, term=True, **pk):
    d = os.path.join(res, "g3", rid)
    params = {"LAD_ARM": arm, "LAD_RUNG": rung, "LAD_COHORT": "1", "LAD_REP": str(rep)}
    params.update(pk)
    manifest(d, rid, params, T0 + start, T0 + start + wall if term else None, phases or {"setup": 5, "classify": 50},
             cost=wall / 1000.0, accessions=accessions, ref=ref)
    lines(d, samples if samples is not None else [sample(arm, rung)])
    if util_mode != "none":
        util(d, util_cost if util_cost is not None else wall / 1000.0, fleet=util_mode == "fleet")


def record(res, variant=""):
    os.makedirs(os.path.join(res, "g3"))
    os.makedirs(os.path.join(res, "cohort", "PRJTEST"))
    with open(os.path.join(res, "cohort", "PRJTEST", "runs.tsv"), "w") as f:
        f.write("rank\trun\tsample\n1\tSRR1\tSAMN1\n2\tSRR2\tSAMN2\n")
    single(res, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000, util_cost=0.9)
    single(res, "20261010-000002-aaaaaaa", "S", "S0-T1", 2, 1010)
    single(res, "20261010-000003-aaaaaaa", "S", "S0-Tv", 1, 600, {"fetch-db": 300, "classify": 40})
    single(res, "20261010-000004-aaaaaaa", "S", "S0-Tv", 2, 620, {"fetch-db": 310, "classify": 40}, util_mode="node")
    single(res, "20261010-000005-aaaaaaa", "S", "S1", 1, 560, {"fetch-db": 100, "classify": 40})
    single(res, "20261010-000006-aaaaaaa", "S", "S1", 2, 600, {"fetch-db": 102, "classify": 40}, util_mode="none")
    single(res, "20261010-000007-aaaaaaa", "S", "S2", 1, 400)
    # S2 rep 2: its S5 identity check failed and the body fell back to gzip: output-preserving, kept.
    single(res, "20261010-000008-aaaaaaa", "S", "S2", 2, 410,
           samples=[sample("S", "S2", s5="differs", fallback="gzip")])
    # O0 rep 1's planned set is a reference (@PRJTEST:1-1 = SRR1), resolved from runs.tsv.
    single(res, "20261010-000009-aaaaaaa", "O", "O0", 1, 300, ref="@PRJTEST:1-1")
    o0 = None
    if variant == "sha":
        o0 = [sample("O", "O0", {"output": {"bytes": 10, "sha256": SHA_BAD}, "report": GOOD["report"]})]
    elif variant == "fileset":
        o0 = [sample("O", "O0", dict(GOOD, classified_1={"bytes": 3, "sha256": SHA_OUT}))]
    elif variant == "o5match":
        o0 = [sample("O", "O0", BAD, s5="differs")]
    elif variant == "o5none":
        o0 = [sample("O", "O0", GOOD, s5="differs")]
    single(res, "20261010-000010-aaaaaaa", "O", "O0", 2, 302, samples=o0)
    # O1 rep 1: a 2-node cohort. Launches T0, T0+1; terminations T0+150, T0+200: wall 200; billed 0.1 + 0.1.
    cid = "20261010-000011-aaaaaaa-1234-n2"
    cd = os.path.join(res, "g3", cid)
    os.makedirs(cd)
    with open(os.path.join(cd, "cohort.json"), "w") as f:
        json.dump({"cohort_id": cid, "gate": "g3", "commit": "e" * 40, "start": iso(T0),
                   "params": {"arm": "O", "rung": "O1", "cohort": 1, "rep": 1},
                   "members": [{"rank": 0, "run_id": cid + "-r0"}, {"rank": 1, "run_id": cid + "-r1"}]}, f)
    util(cd, 0.2)
    manifest(os.path.join(res, "g3", cid + "-r0"), cid + "-r0", {}, T0, T0 + 150, {"load": 20}, cost=0.1, put_params=False)
    manifest(os.path.join(res, "g3", cid + "-r1"), cid + "-r1", {}, T0 + 1, T0 + 200, {"load": 30}, cost=0.1, put_params=False)
    lines(os.path.join(res, "g3", cid + "-r0"), [sample("O", "O1", classify=7.0)])
    lines(os.path.join(res, "g3", cid + "-r1"), [])
    single(res, "20261010-000012-aaaaaaa", "O", "O1", 2, 204, samples=[sample("O", "O1", classify=9.0)])
    if variant != "o5none":
        # S2 rep 3: S5 differs with no fallback and its outputs differ: "S5 not output-preserving on this
        # input", not a DEFECT, out of the attribution (variant s5eq: outputs equal: kept, with a note).
        single(res, "20261010-000013-aaaaaaa", "S", "S2", 3, 100,
               samples=[sample("S", "S2", GOOD if variant == "s5eq" else BAD, s5="differs")])
    # Endpoint runs: cold (feeds the S*-time total) and warm (decomposition only).
    single(res, "20261010-000014-aaaaaaa", "S", "S2", 1, 420, {"classify": 60}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="cold")
    single(res, "20261010-000015-aaaaaaa", "S", "S2", 1, 380, {"classify": 20}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="warm")
    if variant == "incomplete":
        # S1 rep 3 planned SRR1 and SRR2 but emitted SRR1 only: DEFECT incomplete, excluded (S1's median stays 580).
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, {"fetch-db": 1}, accessions=("SRR1", "SRR2"))
    if variant == "rcfail":
        # S1 rep 3's sample failed (rc 2), and rep 4's rc is a string: both DEFECTs, both excluded.
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, {"fetch-db": 1}, samples=[sample("S", "S1", rc=2)])
        single(res, "20261010-000018-aaaaaaa", "S", "S1", 4, 10, {"fetch-db": 1}, samples=[sample("S", "S1", rc="0")])
    if variant == "noref":
        # SRR9 only on the O arm: no upstream reference, a DEFECT.
        single(res, "20261010-000017-aaaaaaa", "O", "O0", 3, 301, accessions=("SRR9",),
               samples=[sample("O", "O0", acc="SRR9")])
    if variant == "noterm":
        single(res, "20261010-000017-aaaaaaa", "S", "S2", 9, 405, term=False, LAD_RUN_KIND="endpoint",
               LAD_ENDPOINT="S*-cost", LAD_STATE="warm")
    if variant == "badparams":
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, LAD_STATE="hot")
        x = sample("S", "S1")
        x["v"] = 2
        single(res, "20261010-000018-aaaaaaa", "S", "S1", 4, 10, samples=[x])
    # A run that is not a ladder run (no params): ignored.
    manifest(os.path.join(res, "g3", "20261010-000016-aaaaaaa"), "x", {}, T0, T0 + 5, {}, put_params=False)
    os.makedirs(os.path.join(res, "g3", "campaign"))
    with open(os.path.join(res, "g3", "campaign", "spend.tsv"), "w") as f:
        f.write("run\tcost_usd\n20261010-000001-aaaaaaa\t1\n")
    with open(os.path.join(res, "levers.tsv"), "w") as f:
        f.write(LEVERS)
    # Modelled values (Scott: stock T1 at c100 is modelled from c10's per-thread rate, flagged).
    with open(os.path.join(res, "g3", "ladder-modelled.tsv"), "w") as f:
        f.write("arm\trung\tcohort\taxis\tvalue\tbasis\tsource\n"
                "S\tS0-T1\t100\twall_s\t5000\tc10 per-thread rate x pairs\tresults/g3/x/tables/rates.tsv\n"
                "S\tS0-Tv\t100\twall_s\t3000\tc10 per-thread rate x pairs\tresults/g3/x/tables/rates.tsv\n")


def run(variant=""):
    tmp = tempfile.mkdtemp(prefix="ladder-test-")
    res = os.path.join(tmp, "results")
    record(res, variant)
    out = os.path.join(tmp, "out")
    rc = lt.main(["--results", res, "--levers", os.path.join(res, "levers.tsv"), "--out", out])
    T = {}
    for n in os.listdir(out):
        if n.endswith(".tsv"):
            with open(os.path.join(out, n)) as f:
                T[n] = list(csv.DictReader(f, delimiter="\t"))
    with open(os.path.join(out, "manifest.json")) as f:
        T["manifest"] = json.load(f)
    with open(os.path.join(out, "summary.md")) as f:
        T["summary"] = f.read()
    shutil.rmtree(tmp)
    return rc, T


def one(rows, **k):
    m = [r for r in rows if all(str(r.get(a)) == str(b) for a, b in k.items())]
    if len(m) != 1:
        FAIL.append(f"expected one row for {k}, got {len(m)}")
        print(f"ladder_tables_test: FAIL expected one row for {k}, got {len(m)}")
        return {}
    return m[0]


def base():
    rc, T = run()
    check("base record exits 0", rc, 0)
    runs = T["runs.tsv"]
    check("ladder runs found (15: the no-params dir ignored, the cohort counted once)", len(runs), 15)
    r = one(runs, run_id="20261010-000001-aaaaaaa")
    check("S0-T1 rep 1 wall", r.get("wall_s"), 1000.0)
    check("S0-T1 rep 1 billed (manifest)", r.get("billed_usd"), 1.0)
    check("U_cpu from the fleet row, not the node row", r.get("U_cpu"), 0.5)
    check("eff numerator is the fleet cost_usd: eff_cpu = 0.9 / 0.5", r.get("eff_cpu_usd"), 1.8)
    check("eff_mem = 0.9 / 0.25", r.get("eff_mem_usd"), 3.6)
    check("eff_net_rx_baseline = 0.9 / 0.06", r.get("eff_net_rx_baseline_usd"), 0.9 / 0.06)
    check("eff_net_tx_peak = 0.9 / 0.02", r.get("eff_net_tx_peak_usd"), 45.0)
    for rid, why in (("20261010-000006-aaaaaaa", "no util.tsv"), ("20261010-000004-aaaaaaa", "a node row only")):
        r = one(runs, run_id=rid)
        check(f"missing util ({why}): U_cpu empty", r.get("U_cpu"), "")
        check(f"missing util ({why}): eff_cpu empty", r.get("eff_cpu_usd"), "")
        check(f"missing util ({why}): coverage says missing", r.get("util_coverage"), "missing (no tables/util.tsv fleet row)")
    e = one(T["effcost.tsv"], rung="S1", metric="eff_cpu_usd")
    check("S1 eff_cpu n = 1", e.get("n"), "1")
    check("S1 eff_cpu median = 0.560 / 0.5", e.get("median"), 1.12)
    check("S1 effcost note names the missing run", e.get("note"), "util missing on 1 of 2 run(s): not imputed")
    check("S1 effcost carries util coverage", e.get("util_coverage"), "full | missing (no tables/util.tsv fleet row)")
    t = [x for x in T["tidy.tsv"] if x["run_id"] == "20261010-000006-aaaaaaa" and x["metric"] == "U_cpu"]
    check("tidy: missing U_cpu is 'missing'", t[0]["value"] if t else None, "missing")
    r = one(runs, run_id="20261010-000009-aaaaaaa")
    check("planned set resolved from the reference", (r.get("planned_samples"), r.get("in_attribution")), ("1", "yes"))
    r = one(runs, run_id="20261010-000011-aaaaaaa-1234-n2")
    check("cohort wall = last termination - first launch", r.get("wall_s"), 200.0)
    check("cohort billed = sum of members", r.get("billed_usd"), 0.2)
    check("O1 lever phase sample:classify = 7", r.get("lever_phase_s"), 7.0)
    # Per-rung stats.
    g = one(T["rungs.tsv"], rung="S1", axis="wall_s", cohort=1)
    check("S1 wall median, range, q", (g.get("median"), g.get("range"), g.get("granularity_q")),
          ("580.000000", "40.000000", "2.000000"))
    g = one(T["rungs.tsv"], rung="S2", axis="wall_s", cohort=1)
    check("S2: the fallback run kept, the non-preserving run out: n 2, median 405", (g.get("n"), g.get("median")),
          ("2", "405.000000"))
    g = one(T["rungs.tsv"], rung="O1", axis="billed_usd", cohort=1)
    check("O1 billed median 0.202, q = 0.002 x 2 nodes", (g.get("median"), g.get("granularity_q")), ("0.202000", "0.004000"))
    g = one(T["rungs.tsv"], rung="S0-T1", axis="wall_s", cohort=100)
    check("modelled c100 row: basis flagged, n 1", (g.get("basis", "")[:18], g.get("n"), g.get("median")),
          ("modelled (flagged)", "1", "5000.000000"))
    # Deltas.
    d = one(T["deltas.tsv"], rung="S1", axis="wall_s", cohort=1)
    check("S1 wall delta -30, threshold 80, UNRESOLVABLE (never a null)",
          (d.get("delta"), d.get("threshold"), d.get("status")), ("-30.000000", "80.000000", "unresolvable: |delta| <= 2 x spread"))
    check("S1 predicted -50 vs threshold 80: no", (d.get("predicted_delta"), d.get("predicted_resolvable")), ("-50.000000", "no"))
    d = one(T["deltas.tsv"], rung="S1", axis="lever_phase_s", cohort=1)
    check("S1 own phase -204, q 1, threshold 20: resolved", (d.get("delta"), d.get("granularity_q"), d.get("status")),
          ("-204.000000", "1.000000", "resolved"))
    d = one(T["deltas.tsv"], rung="O0", axis="lever_phase_s", cohort=1)
    check("O0 own phase 0 with zero spread: below instrument granularity", (d.get("delta"), d.get("threshold"), d.get("status")),
          ("0.000000", "2.000000", "unresolvable: below instrument granularity"))
    d = one(T["deltas.tsv"], rung="O1", axis="billed_usd", cohort=1)
    check("O1 billed -0.099, threshold 2 x max(0.004, 0.002, 0.004)", (d.get("delta"), d.get("threshold"), d.get("status")),
          ("-0.099000", "0.008000", "resolved"))
    d = one(T["deltas.tsv"], rung="S0-Tv", axis="wall_s", cohort=100)
    check("a delta on modelled values is flagged, not resolved", (d.get("delta"), d.get("status")),
          ("-2000.000000", "modelled (flagged): not a measurement, not resolvable"))
    # Pairs.
    P = T["pairs.tsv"]

    def pair(name, src, ax):
        rows = [x for x in P if x["pair"] == name and x["source"] == src and x["axis"] == ax and x["cohort"] == "1"]
        return [float(x["delta"]) for x in rows if x["row"] == "lever"], next((x for x in rows if x["row"] == "total"), {})
    lev, tot = pair("S vs O*", "S0-T1", "wall_s")
    check("S vs O* wall: lever deltas", lev, [-395.0, -30.0, -175.0, -104.0, -99.0])
    check("S vs O* wall: total, sum, residual (identity)", (tot.get("delta"), tot.get("sum_of_lever_deltas"),
          tot.get("residual_total_minus_sum")), ("-803.000000", "-803.000000", "0.000000"))
    check("S vs O* residual noted as an identity", "residual is an identity" in tot.get("note", ""), True)
    check("S vs O* ratio beside the total (1005 / 202)", tot.get("ratio_source_over_target"), 1005 / 202)
    check("S vs O* basis: per-cohort declaration", tot.get("endpoint_basis"),
          "source S0-T1: stock rung; target O1: declared for c1")
    lev, tot = pair("S vs S*", "S0-T1", "wall_s")
    check("S vs S* wall: lever deltas", lev, [-395.0, -30.0, -175.0])
    check("S vs S* wall: total from the cold endpoint run (420 - 1005), n 1",
          (tot.get("delta"), tot.get("status"), tot.get("sum_of_lever_deltas"), tot.get("residual_total_minus_sum")),
          ("-585.000000", "unresolvable: n < 2 (n 1 vs 2), no spread", "-600.000000", "15.000000"))
    lev, tot = pair("S vs S*", "S0-Tv", "wall_s")
    check("S vs S* from S0-Tv: one fewer lever", lev, [-30.0, -175.0])
    lev, tot = pair("S vs S*", "S0-T1", "billed_usd")
    check("S vs S* billed (no cost endpoint run): sum = total, residual 0",
          (lev, tot.get("delta"), tot.get("sum_of_lever_deltas"), tot.get("residual_total_minus_sum")),
          ([-0.395, -0.03, -0.175], "-0.600000", "-0.600000", "0.000000"))
    lev, tot = pair("S* vs O*", "S2", "eff_cpu_usd")
    # S2 eff_cpu 0.4/0.5, 0.41/0.5 -> 0.81; O1 0.2/0.5, 0.204/0.5 -> 0.404
    check("S* vs O* eff_cpu total and util coverage", (tot.get("delta"), tot.get("util_coverage")), ("-0.406000", "full"))
    t100 = [x for x in P if x["cohort"] == "100" and x["pair"] == "S vs O*" and x["axis"] == "wall_s"]
    check("O* not declared at c100", [x["status"] for x in t100], ["endpoint not declared", "endpoint not declared"])
    # Law 1 and S5.
    l1 = one(T["law1.tsv"], accession="SRR1")
    check("Law 1 identical across arms, stock reference", (l1.get("status"), l1.get("reference")),
          ("identical", "20261010-000001-aaaaaaa (S0-T1)"))
    s5 = sorted((x["run_id"], x["s5_fallback"], x["status"]) for x in T["s5-nonpreserving.tsv"])
    check("S5 rows: the fallback (kept) and the non-preserving one (exempt)", s5,
          [("20261010-000008-aaaaaaa", "gzip", "identical"),
           ("20261010-000013-aaaaaaa", "none", "S5 not output-preserving on this input")])
    check("S5 non-preserving run out of the attribution",
          one(runs, run_id="20261010-000013-aaaaaaa").get("in_attribution", "")[:3], "no:")
    check("S5 fallback run in the attribution", one(runs, run_id="20261010-000008-aaaaaaa").get("in_attribution"), "yes")
    check("summary: the finding against the lever (1 of 1 input)",
          "S2: S5 not output-preserving on 1 of 1 inputs (fell back to gzip): SRR1" in T["summary"], True)
    check("summary: lever rows under a pair total", "| | | | | | | lever 3 | S2 (rapidgzip) | -175.000000 | resolved |" in T["summary"],
          True)
    check("summary: endpoint basis column", "| endpoint basis |" in T["summary"], True)
    # Endpoint rows.
    ep = T["endpoints.tsv"]
    check("endpoint cold and warm walls", (one(ep, state="cold", metric="wall_s").get("median"),
                                           one(ep, state="warm", metric="wall_s").get("median")), ("420.000000", "380.000000"))
    check("endpoint warm classify phase", one(ep, state="warm", metric="phase.classify").get("median"), 20.0)
    # Spend and the manifest.
    sp = T["spend.tsv"]
    check("spend: in / not in the campaign spend.tsv", (one(sp, run_id="20261010-000001-aaaaaaa").get("in_campaign_spend"),
          one(sp, run_id="20261010-000002-aaaaaaa").get("in_campaign_spend")), ("yes", "NO"))
    # 1.000+1.010+0.600+0.620+0.560+0.600+0.400+0.410+0.300+0.302+0.200+0.204+0.100+0.420+0.380 = 7.106
    check("spend total", one(sp, run_id="TOTAL").get("billed_usd"), 7.106)
    man = T["manifest"]
    paths = [i["path"] for i in man["inputs"]]
    check("manifest cites levers, modelled, runs.tsv and every ladder manifest (not the non-ladder one)",
          (any(p.endswith("levers.tsv") for p in paths), any(p.endswith("ladder-modelled.tsv") for p in paths),
           any(p.endswith("PRJTEST/runs.tsv") for p in paths), sum(p.endswith("manifest.json") for p in paths),
           any("000016" in p for p in paths)), (True, True, True, 16, False))


def variants():
    rc, T = run("sha")
    check("sha mismatch exits 1", rc, 1)
    check("sha mismatch: DEFECT", one(T["law1.tsv"], accession="SRR1").get("status"), "DEFECT")
    check("detail names the role", one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa", role="output").get("status"),
          "DEFECT: sha256 differs from reference on output")
    rc, T = run("fileset")
    check("file-set mismatch exits 1", rc, 1)
    check("detail names the extra file", one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa",
                                             role="classified_1").get("status"),
          "DEFECT: file set differs from reference (missing -; extra classified_1)")
    # Scenario A: incomplete and failed runs never enter the medians.
    rc, T = run("incomplete")
    check("incomplete run exits 1", rc, 1)
    r = one(T["runs.tsv"], run_id="20261010-000017-aaaaaaa")
    check("incomplete run excluded with its reason", r.get("in_attribution"),
          "no: DEFECT (incomplete): 1 of 2 planned samples; missing SRR2")
    check("S1 median unchanged by the incomplete run", one(T["rungs.tsv"], rung="S1", axis="wall_s", cohort=1).get("median"), 580.0)
    rc, T = run("rcfail")
    check("failed sample exits 1", rc, 1)
    check("rc 2: excluded", one(T["runs.tsv"], run_id="20261010-000017-aaaaaaa").get("in_attribution"),
          "no: DEFECT (sample failed): SRR1 rc 2")
    check("rc '0' (a string): contract DEFECT, excluded",
          one(T["runs.tsv"], run_id="20261010-000018-aaaaaaa").get("in_attribution"), "no: DEFECT (contract) in its lad-sample lines")
    check("S1 n and median unchanged", (one(T["rungs.tsv"], rung="S1", axis="wall_s", cohort=1).get("n"),
                                        one(T["rungs.tsv"], rung="S1", axis="wall_s", cohort=1).get("median")), ("2", "580.000000"))
    rc, T = run("noref")
    check("an O-only accession exits 1", rc, 1)
    l1 = one(T["law1.tsv"], accession="SRR9")
    check("O-only accession: DEFECT, no reference", (l1.get("status"), l1.get("reference")), ("DEFECT", "none"))
    check("O-only accession detail: no upstream reference, never identical",
          one(T["law1-detail.tsv"], accession="SRR9", role="output").get("status"), "no upstream reference")
    rc, T = run("o5match")
    check("O-arm s5 differs matching the S entry with the same decompressor status: exit 0", rc, 0)
    d = one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa", role="output")
    check("O-arm s5 differs: compared to the S differs entry", d.get("status"),
          "identical to the S entry with the same decompressor status (20261010-000013-aaaaaaa)")
    check("O-arm s5 differs run out of the attribution",
          one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution", "")[:3], "no:")
    rc, T = run("o5none")
    check("O-arm s5 differs with no S entry of that status: exit 1", rc, 1)
    check("O-arm s5 differs with no S entry: DEFECT", one(T["law1.tsv"], accession="SRR1").get("status"), "DEFECT")
    rc, T = run("s5eq")
    check("S5 differs, no fallback, outputs equal: exit 0", rc, 0)
    r = one(T["runs.tsv"], run_id="20261010-000013-aaaaaaa")
    check("S5 differs, outputs equal: kept, with a note", (r.get("in_attribution"),
          "s5 differs with no fallback, but the outputs equal the reference" in r.get("notes", "")), ("yes", True))
    rc, T = run("noterm")
    r = one(T["runs.tsv"], run_id="20261010-000017-aaaaaaa")
    check("no terminated_at: wall missing (no start/stop fallback), with a note",
          (r.get("wall_s"), "wall missing (no fallback)" in r.get("notes", "")), ("", True))
    rc, T = run("badparams")
    check("bad PARAMS enum and bad v: exit 1", rc, 1)
    check("state 'hot' is a contract DEFECT", one(T["runs.tsv"], run_id="20261010-000017-aaaaaaa").get("in_attribution", "")
          .startswith("no: DEFECT (contract): params state 'hot'"), True)
    check("v 2 is a contract DEFECT", any("v 2 is not 1" in d for d in T["manifest"]["defects"]), True)


def units():
    s = lambda *v: lt.stats([(x, 2.0) for x in v])
    check("n < 2 is unresolvable, never null", lt.delta(s(10.0), s(1.0, 2.0))["status"], "unresolvable: n < 2 (n 1 vs 2), no spread")
    check("missing side", lt.delta(lt.stats([]), s(1.0, 2.0))["status"], "missing: rung has no runs")
    check("|delta| exactly 2 x spread is unresolvable", lt.delta(s(15.0, 17.0), s(5.0, 10.0))["status"],
          "unresolvable: |delta| <= 2 x spread")
    check("zero spread, sub-granularity delta (1 s, q 2 s): below instrument granularity",
          lt.delta(s(5.0, 5.0), s(4.0, 4.0))["status"], "unresolvable: below instrument granularity")
    check("zero spread, delta above 2 q resolves", lt.delta(s(10.0, 10.0), s(4.0, 4.0))["status"], "resolved")
    check("unknown granularity (no price) is unresolvable",
          lt.delta(lt.stats([(1.0, None), (1.0, None)]), s(9.0, 9.0))["status"], "unresolvable: instrument granularity unknown")
    check("the median of 2 is their mean", lt.stats([(1.0, 0), (4.0, 0)])["median"], 2.5)
    lv = {"S0-T1": {"arm": "S", "endpoint": "S*-time", "lever": "stock", "predecessor": ""},
          "S1": {"arm": "S", "endpoint": "c1:S*-time;c10:S*-time", "lever": "x", "predecessor": "S0-T1"},
          "S2": {"arm": "S", "endpoint": "c10:S*-time", "lever": "y", "predecessor": "S1"}}
    m, errs = lt.declared_endpoints(lv)
    check("two rungs declaring the same endpoint at one cohort is an error", errs,
          ["ladder.levers.tsv: S*-time at cohort 10 declared by both S1 and S2"])
    check("per-cohort declaration wins over the global one", lt.endpoint_rung(m, "S*-time", 1), ("S1", "declared for c1"))
    check("global declaration elsewhere", lt.endpoint_rung(m, "S*-time", 100), ("S0-T1", "declared"))
    check("undeclared", lt.endpoint_rung(m, "O*-cost", 1), (None, "endpoint not declared"))
    check("stock rungs: the stock root and its threads child",
          lt.stock_rungs({"S0-T1": {"arm": "S", "lever": "stock", "predecessor": ""},
                          "S0-Tv": {"arm": "S", "lever": "threads", "predecessor": "S0-T1"},
                          "S1": {"arm": "S", "lever": "s5cmd", "predecessor": "S0-Tv"}}), ["S0-T1", "S0-Tv"])
    bad = {"run_id": "r", "params": {"arm": "S", "rung": "S1", "cohort": 1}, "samples": [
        {"v": 1, "arm": "S", "rung": "S2", "cohort": 1, "accession": "X", "pairs": 1, "rc": 0, "phases": {},
         "outputs": {"output": {"bytes": 1, "sha256": "zz"}}, "s5": {"status": "maybe"}, "_node": "r"}]}
    check("contract: rung mismatch, no report, bad sha, bad s5 (4 errors)", len(lt.contract_errors(bad)), 4)
    bad["samples"][0].update(rung="S1", outputs=GOOD, s5={"status": "n/a", "fallback": "gzip"})
    check("contract: fallback gzip without differs", lt.contract_errors(bad), ["r r X: s5.fallback gzip without s5.status differs"])


def main():
    base()
    variants()
    units()
    print(f"ladder_tables_test: {'FAIL ' + str(len(FAIL)) if FAIL else 'all ok'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
