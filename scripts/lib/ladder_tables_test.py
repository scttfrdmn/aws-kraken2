#!/usr/bin/env python3
"""make test: scripts/lib/ladder_tables.py on a synthetic ladder record (synthetic data is for unit
tests only; CLAUDE.md Law 3). Every expected value is worked by hand in the comments below.

The record: one accession (SRR1) at cohort 1; rungs S0-T1 -> S0-Tv -> S1 -> S2 -> O0 -> O1, n = 2
each. Price 3.6 $/h, so billed $ = wall s / 1000. Walls (s), median, range:
  S0-T1 1000, 1010 -> 1005, 10      S0-Tv 600, 620 -> 610, 20     S1 560, 600 -> 580, 40
  S2    400, 410   -> 405, 10       O0    300, 302 -> 301, 2      O1 200 (a 2-node cohort), 204 -> 202, 4
Deltas on wall: S0-Tv -395 (threshold 2 x 20 = 40: resolved); S1 -30 (threshold 2 x 40 = 80:
UNRESOLVABLE; predicted -50, |-50| <= 80: predicted_resolvable no); S2 -175 (80: resolved); O0 -104
(threshold 2 x 10 = 20: resolved); O1 -99 (8: resolved).
S1's own phase (run:fetch-db): S0-Tv 300, 310 (305, 10), S1 100, 102 (101, 2): delta -204,
threshold 20: resolved, although its wall delta is unresolvable.
Pairs (time, endpoints declared S2 and O1): S0-T1 -> S2 = 405 - 1005 = -600 = -395 - 30 - 175;
S0-T1 -> O1 = 202 - 1005 = -803 = -600 - 104 - 99; S2 -> O1 = 202 - 405 = -203 = -104 - 99.
Utilisation: U_cpu 0.5, U_mem_mean 0.25, U_net_baseline 0.1, U_net_rx_baseline 0.06 everywhere,
except S1 rep 2, which has no tables/util.tsv: missing, not imputed. S0-T1 rep 1: billed 1.000,
eff_cpu 2.0, eff_mem 4.0, eff_net_baseline 10.0, eff_net_rx_baseline 1/0.06.
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
S0-Tv\tS\tS0-T1\tstock\tO0\trun:classify\t\t
S1\tS\tS0-Tv\ts5cmd-staging\tO0b\trun:fetch-db\t\t-50
S2\tS\tS1\ttmpfs-M\tO0\trun:classify\tS*-time;S*-cost\t
O0\tO\tS2\tplain-path\t-\trun:classify\t\t
O1\tO\tO0\tshards\t-\tsample:classify\tO*-time;O*-cost\t
"""


def sample(arm, rung, outputs=None, s5="n/a", classify=10.0):
    return {"v": 1, "arm": arm, "rung": rung, "cohort": 1, "accession": "SRR1", "idx": 0, "pairs": 1000, "rc": 0,
            "phases": {"classify": classify}, "s5": {"status": s5, "P": 16, "nproc": 192},
            "outputs": outputs or {"output": {"bytes": 10, "sha256": SHA_OUT}, "report": {"bytes": 5, "sha256": SHA_REP}}}


UTIL_HEAD = ["scope", "node", "phase", "U_cpu", "U_mem_mean", "U_mem_peak", "U_net_baseline", "U_net_peak",
             "U_net_rx_baseline", "U_net_rx_peak", "U_net_tx_baseline", "U_net_tx_peak", "coverage"]


def util(d):
    os.makedirs(os.path.join(d, "tables"), exist_ok=True)
    with open(os.path.join(d, "tables", "util.tsv"), "w") as f:
        f.write("\t".join(UTIL_HEAD) + "\n")
        f.write("\t".join(["node", "x", "(billed window)", "0.9"] + ["0.9"] * 8 + ["full"]) + "\n")  # not the fleet row
        f.write("\t".join(["fleet", "1 of 1", "(billed window)", "0.5", "0.25", "0.4", "0.1", "0.05", "0.06", "0.03",
                           "0.04", "0.02", "full"]) + "\n")


def manifest(d, rid, params, launch, term, phases, cost=None, put_params=True):
    os.makedirs(os.path.join(d, "out"), exist_ok=True)
    os.makedirs(os.path.join(d, "log"), exist_ok=True)
    m = {"gate": "g3", "run_id": rid, "commit": "f" * 40, "region": "us-west-2", "truffle_price_usd_per_hour": 3.6,
         "instance": {"type": "x.test", "az": "us-west-2a", "launch_time": iso(launch), "terminated_at": iso(term)},
         "cost_usd": cost if cost is not None else (term - launch) / 1000.0,
         "phases": [{"phase": k, "seconds": v} for k, v in phases.items()]}
    if put_params:
        m["params"] = params
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(m, f)


def lines(d, samples, stream=True):
    with open(os.path.join(d, "out", "lad-samples.jsonl"), "w") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")
    with open(os.path.join(d, "log", "run.log"), "w") as f:
        f.write("[c1] preamble: $- = hB\n")
        if stream:
            for s in samples:
                f.write("[c1] lad-sample " + json.dumps(s) + "\n")


def single(res, rid, arm, rung, rep, wall, phases=None, samples=None, with_util=True, start=0, **pk):
    d = os.path.join(res, "g3", rid)
    params = {"LAD_ARM": arm, "LAD_RUNG": rung, "LAD_COHORT": "1", "LAD_REP": str(rep)}
    params.update(pk)
    manifest(d, rid, params, T0 + start, T0 + start + wall, phases or {"setup": 5, "classify": 50})
    lines(d, samples if samples is not None else [sample(arm, rung)])
    if with_util:
        util(d)


def record(res, variant=""):
    os.makedirs(os.path.join(res, "g3"))
    single(res, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000)
    single(res, "20261010-000002-aaaaaaa", "S", "S0-T1", 2, 1010)
    single(res, "20261010-000003-aaaaaaa", "S", "S0-Tv", 1, 600, {"fetch-db": 300, "classify": 40})
    single(res, "20261010-000004-aaaaaaa", "S", "S0-Tv", 2, 620, {"fetch-db": 310, "classify": 40})
    single(res, "20261010-000005-aaaaaaa", "S", "S1", 1, 560, {"fetch-db": 100, "classify": 40})
    single(res, "20261010-000006-aaaaaaa", "S", "S1", 2, 600, {"fetch-db": 102, "classify": 40}, with_util=False)
    single(res, "20261010-000007-aaaaaaa", "S", "S2", 1, 400)
    single(res, "20261010-000008-aaaaaaa", "S", "S2", 2, 410)
    single(res, "20261010-000009-aaaaaaa", "O", "O0", 1, 300)
    o0 = None
    if variant == "sha":
        o0 = [sample("O", "O0", {"output": {"bytes": 10, "sha256": SHA_BAD}, "report": {"bytes": 5, "sha256": SHA_REP}})]
    elif variant == "fileset":
        o0 = [sample("O", "O0", {"output": {"bytes": 10, "sha256": SHA_OUT}, "report": {"bytes": 5, "sha256": SHA_REP},
                                 "classified_1": {"bytes": 3, "sha256": SHA_OUT}})]
    single(res, "20261010-000010-aaaaaaa", "O", "O0", 2, 302, samples=o0)
    # O1 rep 1: a 2-node cohort. Launches T0, T0+1; terminations T0+150, T0+200: wall 200; billed 0.1 + 0.1.
    cid = "20261010-000011-aaaaaaa-1234-n2"
    cd = os.path.join(res, "g3", cid)
    os.makedirs(cd)
    with open(os.path.join(cd, "cohort.json"), "w") as f:
        json.dump({"cohort_id": cid, "gate": "g3", "commit": "e" * 40, "start": iso(T0),
                   "params": {"arm": "O", "rung": "O1", "cohort": 1, "rep": 1},
                   "members": [{"rank": 0, "run_id": cid + "-r0"}, {"rank": 1, "run_id": cid + "-r1"}]}, f)
    util(cd)
    manifest(os.path.join(res, "g3", cid + "-r0"), cid + "-r0", {}, T0, T0 + 150, {"load": 20}, cost=0.1, put_params=False)
    manifest(os.path.join(res, "g3", cid + "-r1"), cid + "-r1", {}, T0 + 1, T0 + 200, {"load": 30}, cost=0.1, put_params=False)
    lines(os.path.join(res, "g3", cid + "-r0"), [sample("O", "O1", classify=7.0)])
    lines(os.path.join(res, "g3", cid + "-r1"), [])
    single(res, "20261010-000012-aaaaaaa", "O", "O1", 2, 204, samples=[sample("O", "O1", classify=9.0)])
    # An S5 run whose sample is not output-preserving: reported as such, never a DEFECT, out of the attribution.
    single(res, "20261010-000013-aaaaaaa", "S", "S2", 3, 100,
           samples=[sample("S", "S2", {"output": {"bytes": 9, "sha256": SHA_BAD}, "report": {"bytes": 5, "sha256": SHA_REP}},
                           s5="differs")])
    # Endpoint decomposition runs: cold and warm rows.
    single(res, "20261010-000014-aaaaaaa", "S", "S2", 1, 420, {"classify": 60}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="cold")
    single(res, "20261010-000015-aaaaaaa", "S", "S2", 1, 380, {"classify": 20}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="warm")
    # A run that is not a ladder run (no params): ignored.
    manifest(os.path.join(res, "g3", "20261010-000016-aaaaaaa"), "x", {}, T0, T0 + 5, {}, put_params=False)
    os.makedirs(os.path.join(res, "g3", "campaign"))
    with open(os.path.join(res, "g3", "campaign", "spend.tsv"), "w") as f:
        f.write("run\tcost_usd\n20261010-000001-aaaaaaa\t1\n")
    with open(os.path.join(res, "levers.tsv"), "w") as f:
        f.write(LEVERS)


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
    shutil.rmtree(tmp)
    return rc, T


def one(rows, **k):
    m = [r for r in rows if all(str(r.get(a)) == str(b) for a, b in k.items())]
    if len(m) != 1:
        FAIL.append(f"expected one row for {k}, got {len(m)}")
        print(f"ladder_tables_test: FAIL expected one row for {k}, got {len(m)}")
        return {}
    return m[0]


def main():
    rc, T = run()
    check("clean record exits 0", rc, 0)
    runs = T["runs.tsv"]
    check("ladder runs found (15: the no-params dir ignored, the cohort counted once)", len(runs), 15)
    r = one(runs, run_id="20261010-000001-aaaaaaa")
    check("S0-T1 rep 1 wall", r.get("wall_s"), 1000.0)
    check("S0-T1 rep 1 billed", r.get("billed_usd"), 1.0)
    check("U_cpu taken from the fleet row, not the node row", r.get("U_cpu"), 0.5)
    check("eff_cpu = 1.0 / 0.5", r.get("eff_cpu_usd"), 2.0)
    check("eff_mem = 1.0 / 0.25", r.get("eff_mem_usd"), 4.0)
    check("eff_net_baseline = 1.0 / 0.1", r.get("eff_net_baseline_usd"), 10.0)
    check("eff_net_rx_baseline = 1.0 / 0.06", r.get("eff_net_rx_baseline_usd"), 1 / 0.06)
    check("eff_net_tx_peak = 1.0 / 0.02", r.get("eff_net_tx_peak_usd"), 50.0)
    # Missing util row: reported as missing, not imputed.
    r = one(runs, run_id="20261010-000006-aaaaaaa")
    check("missing util: U_cpu empty", r.get("U_cpu"), "")
    check("missing util: eff_cpu empty", r.get("eff_cpu_usd"), "")
    check("missing util: coverage says missing", r.get("util_coverage"), "missing (no tables/util.tsv fleet row)")
    e = one(T["effcost.tsv"], rung="S1", metric="eff_cpu_usd")
    check("S1 eff_cpu n = 1 (one run has no util)", e.get("n"), "1")
    check("S1 eff_cpu median = 0.560 / 0.5", e.get("median"), 1.12)
    check("S1 eff_cpu range n<2", e.get("range"), "n<2")
    check("S1 effcost note names the missing run", e.get("note"), "util missing on 1 of 2 run(s): not imputed")
    t = [x for x in T["tidy.tsv"] if x["run_id"] == "20261010-000006-aaaaaaa" and x["metric"] == "U_cpu"]
    check("tidy: missing U_cpu is 'missing'", t[0]["value"] if t else None, "missing")
    # The cohort run.
    r = one(runs, run_id="20261010-000011-aaaaaaa-1234-n2")
    check("cohort wall = last termination - first launch", r.get("wall_s"), 200.0)
    check("cohort billed = sum of members", r.get("billed_usd"), 0.2)
    check("cohort nodes", r.get("nodes"), "2")
    check("O1 lever phase sample:classify = 7", r.get("lever_phase_s"), 7.0)
    # Per-rung medians and ranges.
    g = one(T["rungs.tsv"], rung="S1", axis="wall_s")
    check("S1 wall median", g.get("median"), 580.0)
    check("S1 wall range", g.get("range"), 40.0)
    g = one(T["rungs.tsv"], rung="S2", axis="wall_s")
    check("S2 excludes the S5 non-preserving run: n", g.get("n"), "2")
    check("S2 wall median", g.get("median"), 405.0)
    g = one(T["rungs.tsv"], rung="O1", axis="billed_usd")
    check("O1 billed median (0.200, 0.204)", g.get("median"), 0.202)
    # Deltas and the resolution rule.
    d = one(T["deltas.tsv"], rung="S1", axis="wall_s")
    check("S1 wall delta", d.get("delta"), -30.0)
    check("S1 wall threshold 2 x max(40, 20)", d.get("threshold_2x_spread"), 80.0)
    check("S1 wall delta UNRESOLVABLE (never a null)", d.get("status"), "unresolvable: |delta| <= 2 x spread")
    check("S1 predicted -50 vs threshold 80: predicted_resolvable no", d.get("predicted_resolvable"), "no")
    check("S1 predicted delta shown", d.get("predicted_delta"), -50.0)
    d = one(T["deltas.tsv"], rung="S1", axis="lever_phase_s")
    check("S1 own phase delta (fetch-db) 101 - 305", d.get("delta"), -204.0)
    check("S1 own phase resolved (threshold 20)", d.get("status"), "resolved")
    d = one(T["deltas.tsv"], rung="S2", axis="wall_s")
    check("S2 wall delta resolved", (d.get("delta"), d.get("status")), ("-175.000000", "resolved"))
    d = one(T["deltas.tsv"], rung="S1", axis="billed_usd")
    check("S1 billed delta -0.030, unresolvable (threshold 0.080)", (d.get("delta"), d.get("status")),
          ("-0.030000", "unresolvable: |delta| <= 2 x spread"))
    # Pairs: the per-lever decomposition sums to the total.
    P = T["pairs.tsv"]
    for pair, src, total, levers in (("S vs S*", "S0-T1", -600.0, [-395.0, -30.0, -175.0]),
                                     ("S vs O*", "S0-T1", -803.0, [-395.0, -30.0, -175.0, -104.0, -99.0]),
                                     ("S vs S*", "S0-Tv", -205.0, [-30.0, -175.0]),
                                     ("S* vs O*", "S2", -203.0, [-104.0, -99.0])):
        rows = [x for x in P if x["pair"] == pair and x["source"] == src and x["axis"] == "wall_s"]
        tot = [x for x in rows if x["row"] == "total"]
        lev = [float(x["delta"]) for x in rows if x["row"] == "lever"]
        check(f"{pair} from {src}: lever deltas", lev, levers)
        check(f"{pair} from {src}: total", tot[0]["delta"] if tot else None, total)
        check(f"{pair} from {src}: sum of lever deltas = total", tot[0]["sum_of_lever_deltas"] if tot else None, total)
        check(f"{pair} from {src}: residual 0", tot[0]["residual_total_minus_sum"] if tot else None, 0.0)
    tot = one(P, pair="S vs O*", source="S0-T1", axis="wall_s", row="total")
    check("S vs O* ratio beside the total (1005 / 202)", tot.get("ratio_source_over_target"), 1005 / 202)
    check("S vs O* endpoint basis declared", tot.get("endpoint_basis"), "O*: declared in ladder.levers.tsv")
    tot = one(P, pair="S* vs O*", axis="billed_usd", row="total")
    check("S* vs O* on the cost endpoint: billed delta 0.202 - 0.405", tot.get("delta"), -0.203)
    tot = one(P, pair="S* vs O*", axis="eff_cpu_usd", row="total")
    check("S* vs O* eff_cpu: 0.404 - 0.810", tot.get("delta"), -0.406)
    # Law 1.
    l1 = one(T["law1.tsv"], accession="SRR1")
    check("Law 1 identical across arms", l1.get("status"), "identical")
    check("Law 1 reference is a stock run", l1.get("reference"), "20261010-000001-aaaaaaa (S0-T1)")
    s5 = T["s5-nonpreserving.tsv"]
    check("S5 non-preserving reported separately", [(x["run_id"], x["outputs_equal_reference"]) for x in s5],
          [("20261010-000013-aaaaaaa", "no")])
    r = one(runs, run_id="20261010-000013-aaaaaaa")
    check("S5 non-preserving run out of the attribution", r.get("in_attribution", "")[:3], "no:")
    # Cold and warm endpoint rows.
    ep = T["endpoints.tsv"]
    check("endpoint cold wall", one(ep, state="cold", metric="wall_s").get("median"), 420.0)
    check("endpoint warm wall", one(ep, state="warm", metric="wall_s").get("median"), 380.0)
    check("endpoint warm classify phase", one(ep, state="warm", metric="phase.classify").get("median"), 20.0)
    # Spend and the manifest.
    sp = T["spend.tsv"]
    check("spend: a run in the campaign spend.tsv", one(sp, run_id="20261010-000001-aaaaaaa").get("in_campaign_spend"), "yes")
    check("spend: a run missing from it", one(sp, run_id="20261010-000002-aaaaaaa").get("in_campaign_spend"), "NO")
    tot = one(sp, run_id="TOTAL")
    # 1.000+1.010+0.600+0.620+0.560+0.600+0.400+0.410+0.300+0.302+0.200+0.204+0.100+0.420+0.380 = 7.106
    check("spend total", tot.get("billed_usd"), 7.106)
    man = T["manifest"]
    paths = [i["path"] for i in man["inputs"]]
    check("manifest cites the levers and every ladder manifest, not the non-ladder one",
          (any(p.endswith("levers.tsv") for p in paths), sum(p.endswith("manifest.json") for p in paths),
           any("000016" in p for p in paths)), (True, 16, False))
    check("manifest inputs carry sha256", all(len(i["sha256"]) == 64 for i in man["inputs"]), True)

    # A sha mismatch: DEFECT, non-zero exit.
    rc, T = run("sha")
    check("sha mismatch exits non-zero", rc, 1)
    l1 = one(T["law1.tsv"], accession="SRR1")
    check("sha mismatch is a DEFECT", l1.get("status"), "DEFECT")
    d = one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa", role="output")
    check("detail names the differing role", d.get("status"), "DEFECT: sha256 differs on output")
    # A file-set mismatch: DEFECT, non-zero exit.
    rc, T = run("fileset")
    check("file-set mismatch exits non-zero", rc, 1)
    d = one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa", role="classified_1")
    check("detail names the extra file", d.get("status"), "DEFECT: file set differs (missing -; extra classified_1)")

    # The resolution rule itself.
    s = lambda *v: lt.stats(list(v))
    check("n < 2 is unresolvable, never null", lt.delta(s(10.0), s(1.0, 2.0))["status"], "unresolvable: n < 2 (n 1 vs 2), no spread")
    check("missing side", lt.delta(s(), s(1.0, 2.0))["status"], "missing: rung has no runs")
    check("|delta| exactly 2 x spread is unresolvable", lt.delta(s(5.0, 7.0), s(1.0, 3.0))["status"],
          "unresolvable: |delta| <= 2 x spread")
    check("zero spread, non-zero delta resolves", lt.delta(s(5.0, 5.0), s(1.0, 1.0))["status"], "resolved")
    # Contract errors are DEFECTs.
    bad = {"run_id": "r", "params": {"arm": "S", "rung": "S1", "cohort": 1}, "samples": [
        {"v": 1, "arm": "S", "rung": "S2", "cohort": 1, "accession": "X", "pairs": 1, "rc": 0, "phases": {},
         "outputs": {"output": {"bytes": 1, "sha256": "zz"}}, "s5": {"status": "maybe"}, "_node": "r"}]}
    errs = lt.contract_errors(bad)
    check("contract: rung mismatch, no report, bad sha, bad s5 (4 errors)", len(errs), 4)

    print(f"ladder_tables_test: {'FAIL ' + str(len(FAIL)) if FAIL else 'all ok'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
