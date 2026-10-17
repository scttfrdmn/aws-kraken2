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
Modelled (make g3-ladder-model, ladder_model.py): two c10 S0-T1 runs, each with SRR1 and SRR2 at
1000 pairs. A: wall 3000, classify 1000 + 1000: per-sample S 2000, fixed 1000, rate 1 pair/s.
B: wall 3100, 1050 + 1050: S 2100, fixed 1000, rate 2000/2100. Target @PRJTEST:1-2 = 3000 + 1000
= 4000 pairs: A 1000 + 4000 = 5000, B 1000 + 4200 = 5200; median 5100 s, billed 5.1 $.
At c100 S0-Tv is measured (3000, 3010 -> 3005) and declared c100:S*-time: S vs S* at c100 from
S0-T1 = 3005 - 5100 = -2095, modelled (flagged). The same model at c1 is ignored (measured runs).
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
import ladder_model  # noqa: E402

FAIL = []
SHA_OUT, SHA_REP, SHA_BAD = "a" * 64, "b" * 64, "c" * 64
GZ, RG1, RG2 = "d" * 64, "e" * 64, "f" * 64  # gzip's decompressed output; two different rapidgzip outputs
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
rung\tarm\tpredecessor\tlever\tcounterpart\tphase\tendpoint\tpred_wall_s\tstatus
S0-T1\tS\t-\tstock\tO0\trun:classify\t\t
S0-Tv\tS\tS0-T1\tthreads\tO0\trun:classify\tc100:S*-time\t
S1\tS\tS0-Tv\ts5cmd-staging\tO0b\trun:fetch-db\t\t-50
S2\tS\tS1\trapidgzip\tO0\trun:classify\tS*-time;S*-cost\t
S3\tS\tS2\thosttune\tO0\trun:classify\t\t\tnot-run: no parameter change (the tune probe chose none)
O0\tO\tS3\tplain-path\t-\trun:classify\t\t
O1\tO\tO0\tshards\t-\tsample:classify\tc1:O*-time;c1:O*-cost\t
"""
GOOD = {"output": {"bytes": 10, "sha256": SHA_OUT}, "report": {"bytes": 5, "sha256": SHA_REP}}
BAD = {"output": {"bytes": 9, "sha256": SHA_BAD}, "report": {"bytes": 5, "sha256": SHA_REP}}


def sample(arm, rung, outputs=None, s5="n/a", fallback=None, classify=10.0, acc="SRR1", rc=0, cohort=1, rg=RG1,
           t0=None, t1=None, extra=None):
    s5o = {"status": s5, "P": 16, "nproc": 192}
    if fallback:
        s5o["fallback"] = fallback
    if s5 != "n/a":
        s5o["gz_sha256"] = [GZ]
        s5o["rg_sha256"] = [GZ if s5 == "identical" else rg]
        s5o["gz_exit"], s5o["rg_exit"] = [0], [139 if fallback == "gzip-crash" else 0]
        if fallback == "gzip-crash":
            s5o["fallback"] = "gzip"
    t0 = T0 + 1 if t0 is None else t0
    return {"v": 1, "arm": arm, "rung": rung, "cohort": cohort, "accession": acc, "idx": 0, "pairs": 1000, "rc": rc,
            "t_start": t0, "t_end": t0 + classify if t1 is None else t1,
            "phases": dict({"classify": classify}, **(extra or {})), "s5": s5o, "outputs": outputs or GOOD}


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


def lines(d, samples, crit=0.0, rank=0, net="ok"):
    """lad-sample lines, and the node's one lad-net line (net: ok, none, or a dict to write as given)."""
    with open(os.path.join(d, "out", "lad-samples.jsonl"), "w") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")
    ln = {"v": 1, "rank": rank, "critical_measurement_s": crit} if net == "ok" else net
    if ln != "none":
        with open(os.path.join(d, "out", "lad-net.jsonl"), "w") as f:
            f.write(json.dumps(ln) + "\n")
    with open(os.path.join(d, "log", "run.log"), "w") as f:
        f.write("[c1] preamble: $- = hB\n")
        for s in samples:
            f.write("[c1] lad-sample " + json.dumps(s) + "\n")
        if ln != "none":
            f.write("[c1] lad-net " + json.dumps(ln) + "\n")


def identity_lines(d, objs):
    """out/lad.jsonl (with a non-identity line beside them) and the streamed lad-identity lines."""
    with open(os.path.join(d, "out", "lad.jsonl"), "w") as f:
        f.write(json.dumps({"kind": "config", "params": {}}) + "\n")
        for o in objs:
            f.write(json.dumps(o) + "\n")
    with open(os.path.join(d, "log", "run.log"), "a") as f:
        for o in objs:
            f.write("[c1] lad-identity " + json.dumps(o) + "\n")


def gzfail(x):
    """The identity phase's gzip exited 1 on the input: an input or staging failure."""
    x["s5"]["gz_exit"] = [1]
    return x


def single(res, rid, arm, rung, rep, wall, phases=None, samples=None, util_cost=None, util_mode="fleet", start=0,
           accessions=("SRR1",), ref=None, term=True, cohort=1, crit=0.0, net="ok", **pk):
    d = os.path.join(res, "g3", rid)
    params = {"LAD_ARM": arm, "LAD_RUNG": rung, "LAD_COHORT": str(cohort), "LAD_REP": str(rep)}
    params.update(pk)
    manifest(d, rid, params, T0 + start, T0 + start + wall if term else None, phases or {"setup": 5, "classify": 50},
             cost=wall / 1000.0, accessions=accessions, ref=ref)
    lines(d, samples if samples is not None else [sample(arm, rung)], crit=crit, net=net)
    if util_mode != "none":
        util(d, util_cost if util_cost is not None else wall / 1000.0, fleet=util_mode == "fleet")


def record(res, variant=""):
    os.makedirs(os.path.join(res, "g3"))
    os.makedirs(os.path.join(res, "cohort", "PRJTEST"))
    with open(os.path.join(res, "cohort", "PRJTEST", "runs.tsv"), "w") as f:
        f.write("rank\trun\tsample\tread_count\n1\tSRR1\tSAMN1\t3000\n2\tSRR2\tSAMN2\t1000\n")
    single(res, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000, util_cost=0.9)
    single(res, "20261010-000002-aaaaaaa", "S", "S0-T1", 2, 1010)
    single(res, "20261010-000003-aaaaaaa", "S", "S0-Tv", 1, 600, {"fetch-db": 300, "classify": 40})
    single(res, "20261010-000004-aaaaaaa", "S", "S0-Tv", 2, 620, {"fetch-db": 310, "classify": 40}, util_mode="node")
    single(res, "20261010-000005-aaaaaaa", "S", "S1", 1, 560, {"fetch-db": 100, "classify": 40},
           net="none" if variant == "nonet" else ({"v": 1, "rank": 7, "critical_measurement_s": 0} if variant == "badnet" else "ok"),
           crit=600.0 if variant == "critbig" else 0.0)
    single(res, "20261010-000006-aaaaaaa", "S", "S1", 2, 600, {"fetch-db": 102, "classify": 40}, util_mode="none")
    single(res, "20261010-000007-aaaaaaa", "S", "S2", 1, 400, {"setup": 5, "identity": 30, "classify": 50}, crit=30.0)
    # S2 rep 2: its S5 identity check failed and the body fell back to gzip: output-preserving, kept.
    # Its lad-net carries the components (identity 90 + sha-get 0 + sha-critical 0 = 90).
    single(res, "20261010-000008-aaaaaaa", "S", "S2", 2, 410, {"setup": 5, "identity": 90, "classify": 50},
           net={"v": 1, "rank": 0, "critical_measurement_s": 90.0, "identity_s": 90.0, "sha_get_s": 0.0, "sha_critical_s": 0.0},
           samples=[(gzfail if variant in ("gzfail", "idboth") else (lambda x: x))(
               sample("S", "S2", s5="differs", fallback="gzip", rg=RG1))])
    if variant in ("idline", "idboth"):
        # The body's identity lines (out/lad.jsonl, kind identity; streamed as lad-identity): GNU gzip gave an
        # empty stream on SRR1_1 (input_defect), while the sample's own s5 (idline) shows nothing wrong.
        identity_lines(os.path.join(res, "g3", "20261010-000008-aaaaaaa"),
                       [{"kind": "identity", "file": "SRR1_1.fastq.gz", "sample": "SRR1", "gzip_sha256": lt.EMPTY_SHA,
                         "gzip_exit": 0, "identical": False, "input_defect": True},
                        {"kind": "identity", "file": "SRR1_2.fastq.gz", "sample": "SRR1", "gzip_exit": 0,
                         "identical": True, "input_defect": False}])
    # O0 rep 1's planned set is a reference (@PRJTEST:1-1 = SRR1), resolved from runs.tsv.
    single(res, "20261010-000009-aaaaaaa", "O", "O0", 1, 300, ref="@PRJTEST:1-1")
    o0 = None
    if variant == "sha":
        o0 = [sample("O", "O0", {"output": {"bytes": 10, "sha256": SHA_BAD}, "report": GOOD["report"]})]
    elif variant == "fileset":
        o0 = [sample("O", "O0", dict(GOOD, classified_1={"bytes": 3, "sha256": SHA_OUT}))]
    elif variant == "o5match":
        o0 = [sample("O", "O0", s5="differs", fallback="gzip", rg=RG1)]
    elif variant == "o5none":
        o0 = [sample("O", "O0", s5="differs", fallback="gzip", rg=RG2)]
    elif variant == "o5crash":
        # rapidgzip segfaulted on the O arm (O4b-if4 at c10): its output is a crash's, matching no S entry.
        o0 = [sample("O", "O0", s5="differs", fallback="gzip-crash", rg=RG2)]
    elif variant in ("o5crashmate", "o5crashout"):
        # Two mates, rapidgzip crashed on mate 1. o5crashmate: mate 2 (exit 0) differs from gzip too,
        # so the crash does not exempt it. o5crashout: mate 2 equal, but the kraken2 output differs.
        x = sample("O", "O0", {"output": {"bytes": 10, "sha256": SHA_BAD}, "report": GOOD["report"]} if variant == "o5crashout" else None,
                   s5="differs", fallback="gzip")
        x["s5"].update(gz_sha256=[GZ, GZ], rg_sha256=[RG2, RG2 if variant == "o5crashmate" else GZ],
                       gz_exit=[0, 0], rg_exit=[139, 0])
        o0 = [x]
    single(res, "20261010-000010-aaaaaaa", "O", "O0", 2, 302, samples=o0)
    # O1 rep 1: a 2-node cohort. Launches T0, T0+1; terminations T0+150, T0+200: wall 200; billed 0.1 + 0.1.
    cid = "20261010-000011-aaaaaaa-1234-n2"
    cd = os.path.join(res, "g3", cid)
    os.makedirs(cd)
    # Its planned set is cohort.json's sample_accessions_ref (variant cohortref: @PRJTEST:1-2, while the
    # members' manifests say SRR1 only: incomplete). Variant missingmember: rank 1 never launched
    # (run-multi writes manifest "missing"): DEFECT incomplete, excluded.
    r1 = {"rank": 1, "rc": "1", "manifest": "missing"} if variant == "missingmember" else {"rank": 1, "run_id": cid + "-r1"}
    with open(os.path.join(cd, "cohort.json"), "w") as f:
        json.dump({"cohort_id": cid, "gate": "g3", "commit": "e" * 40, "start": iso(T0), "nodes": 2,
                   "sample_accessions_ref": {"ref": "@PRJTEST:1-2" if variant == "cohortref" else "@PRJTEST:1-1",
                                             "runs_tsv": "results/cohort/PRJTEST/runs.tsv"},
                   "params": {"arm": "O", "rung": "O1", "cohort": 1, "rep": 1},
                   "members": [{"rank": 0, "run_id": cid + "-r0"}, r1]}, f)
    util(cd, 0.2)
    manifest(os.path.join(res, "g3", cid + "-r0"), cid + "-r0", {}, T0, T0 + 150, {"load": 20}, cost=0.1, put_params=False)
    lines(os.path.join(res, "g3", cid + "-r0"), [sample("O", "O1", classify=7.0)], rank=0)
    if variant != "missingmember":
        manifest(os.path.join(res, "g3", cid + "-r1"), cid + "-r1", {}, T0 + 1, T0 + 200, {"load": 30}, cost=0.1,
                 put_params=False)
        lines(os.path.join(res, "g3", cid + "-r1"), [], rank=1)
    single(res, "20261010-000012-aaaaaaa", "O", "O1", 2, 204, samples=[sample("O", "O1", classify=9.0)])
    if variant == "s5none":
        # S2 rep 3: s5 differs with no gzip fallback: a contract DEFECT under the fallback rule.
        single(res, "20261010-000013-aaaaaaa", "S", "S2", 3, 100, samples=[sample("S", "S2", s5="differs")])
    if variant == "rgdisagree":
        # S2 rep 3 fell back too, but its rapidgzip output differs from rep 2's: flagged, not a DEFECT.
        single(res, "20261010-000013-aaaaaaa", "S", "S2", 3, 100,
               samples=[sample("S", "S2", s5="differs", fallback="gzip", rg=RG2)])
    # Endpoint runs: cold (feeds the S*-time total) and warm (decomposition only).
    single(res, "20261010-000014-aaaaaaa", "S", "S2", 1, 420, {"classify": 60}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="cold")
    single(res, "20261010-000015-aaaaaaa", "S", "S2", 1, 380, {"classify": 20}, LAD_RUN_KIND="endpoint",
           LAD_ENDPOINT="S*-time", LAD_STATE="warm")
    if variant == "incomplete":
        # S1 rep 3 planned SRR1 and SRR2 but emitted SRR1 only: DEFECT incomplete, excluded (S1's median stays 580).
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, {"fetch-db": 1, "classify": 1}, accessions=("SRR1", "SRR2"))
    if variant == "rcfail":
        # S1 rep 3's sample failed (rc 2), and rep 4's rc is a string: both DEFECTs, both excluded.
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, {"fetch-db": 1, "classify": 1}, samples=[sample("S", "S1", rc=2)])
        single(res, "20261010-000018-aaaaaaa", "S", "S1", 4, 10, {"fetch-db": 1, "classify": 1}, samples=[sample("S", "S1", rc="0")])
    if variant == "noref":
        # SRR9 only on the O arm: no upstream reference, a DEFECT.
        single(res, "20261010-000017-aaaaaaa", "O", "O0", 3, 301, accessions=("SRR9",),
               samples=[sample("O", "O0", acc="SRR9")])
    if variant == "noterm":
        single(res, "20261010-000017-aaaaaaa", "S", "S2", 9, 405, term=False, LAD_RUN_KIND="endpoint",
               LAD_ENDPOINT="S*-cost", LAD_STATE="warm")
    if variant == "badparams":
        single(res, "20261010-000017-aaaaaaa", "S", "S1", 3, 10, {"fetch-db": 1, "classify": 1}, LAD_STATE="hot")
        x = sample("S", "S1")
        x["v"] = 2
        single(res, "20261010-000018-aaaaaaa", "S", "S1", 4, 10, {"fetch-db": 1, "classify": 1}, samples=[x])
    # A cold endpoint run on a rung that is not the declared S*-time (S2): a note, not used.
    single(res, "20261010-000019-aaaaaaa", "S", "S1", 1, 333, {"setup": 5, "fetch-db": 1, "classify": 50}, LAD_RUN_KIND="endpoint", LAD_ENDPOINT="S*-time",
           LAD_STATE="cold")
    # c10 S0-T1 (the model's input) and c100 S0-Tv (measured).
    # Per-sample spans (union of [t_start, t_end]): A 500-1500 + 1500-2500 = 2000 s; B 500-1550 + 1550-2600 =
    # 2100 s (variant fneg: B's span is 0-3200 = 3200 s > its 3100 s wall: the model is refused; variant
    # c10law1: B's output differs from the stock reference: a Law 1 DEFECT, so B cannot feed the model).
    single(res, "20261010-000020-aaaaaaa", "S", "S0-T1", 1, 3000, cohort=10, accessions=("SRR1", "SRR2"), crit=100.0,
           samples=[sample("S", "S0-T1", acc="SRR1", classify=1000.0, cohort=10, t0=T0 + 500, extra={"sha-critical": 10.0}),
                    sample("S", "S0-T1", acc="SRR2", classify=1000.0, cohort=10, t0=T0 + 1500, extra={"sha-critical": 10.0})])
    bspan = [(T0, T0 + 1600), (T0 + 1600, T0 + 3200)] if variant == "fneg" else [(T0 + 500, T0 + 1550), (T0 + 1550, T0 + 2600)]
    single(res, "20261010-000021-aaaaaaa", "S", "S0-T1", 2, 3100, cohort=10, accessions=("SRR1", "SRR2"),
           samples=[sample("S", "S0-T1", BAD if variant == "c10law1" else GOOD, acc=a, classify=1050.0, cohort=10,
                           t0=t0, t1=t1) for a, (t0, t1) in zip(("SRR1", "SRR2"), bspan)])
    single(res, "20261010-000022-aaaaaaa", "S", "S0-Tv", 1, 3000, {"setup": 5, "fetch-db": 1, "classify": 50}, cohort=100,
           samples=[sample("S", "S0-Tv", cohort=100)])
    single(res, "20261010-000023-aaaaaaa", "S", "S0-Tv", 2, 3010, {"setup": 5, "fetch-db": 1, "classify": 50}, cohort=100,
           samples=[sample("S", "S0-Tv", cohort=100)])
    # A run that is not a ladder run (no params): ignored.
    manifest(os.path.join(res, "g3", "20261010-000016-aaaaaaa"), "x", {}, T0, T0 + 5, {}, put_params=False)
    os.makedirs(os.path.join(res, "g3", "campaign"))
    with open(os.path.join(res, "g3", "campaign", "spend.tsv"), "w") as f:
        f.write("run\tcost_usd\n20261010-000001-aaaaaaa\t1\n")
    with open(os.path.join(res, "levers.tsv"), "w") as f:
        if variant in ("alias", "aliasbad"):
            # Sstar-time: an alias rung (no runs of its own), resolved at c1 to S2 in ladder.resolved.tsv and
            # unresolved elsewhere; O0's predecessor is the alias.
            lv = LEVERS.replace("\tstatus\n", "\tstatus\talias_of\n").replace("O0\tO\tS3\t", "O0\tO\tSstar-time\t")
            lv += "Sstar-time\tS\tS3\tHOST\tO2\trun:classify\t\t\talias: the winner's runs\tS2|S1|S0-Tv\n"
            f.write(lv)
        elif variant == "notruncohort":
            # S1 is not run at c1 (not_run_cohorts): S2's c1 delta is against S0-Tv.
            f.write(LEVERS.replace("\tstatus\n", "\tstatus\tnot_run_cohorts\n")
                    .replace("\t-50\n", "\t-50\t\tc1: the only candidate is S0-Tv's own configuration\n"))
        else:
            f.write(LEVERS)
    if variant in ("alias", "aliasbad"):
        if variant == "aliasbad":
            with open(os.path.join(res, "levers.tsv"), "w") as f:
                f.write(lv)
        with open(os.path.join(res, "resolved.tsv"), "w") as f:
            f.write("origin\tcohort\tkey\tvalue\tsource\nSstar-time\t1\talias\tS2\tresults/g3/20261010-000007-aaaaaaa\n"
                    "S4\t1\tPROCS\t4\tresults/g3/x\n")
            if variant == "aliasbad":
                # A winner outside alias_of, and a second row for (Sstar-time, c1): both DEFECTs.
                f.write("Sstar-time\t10\talias\tS9\tresults/x\nSstar-time\t1\talias\tS1\tresults/y\n")
    if variant == "overlap":
        # A c10 "T1" run whose 10 samples ran concurrently (each 500-1500): union 1000 s < sum 10000 s - 10 ms.
        accs = [f"SRR{10 + k}" for k in range(10)]
        single(res, "20261010-000025-aaaaaaa", "S", "S0-T1", 3, 3000, cohort=10, accessions=accs,
               samples=[sample("S", "S0-T1", acc=a, classify=1000.0, cohort=10, t0=T0 + 500) for a in accs])
    # Modelled values, by ladder_model.py (make g3-ladder-model): c100 from c10, and c1 from c10 (ignored:
    # c1 is measured). Variant handrow adds a hand-entered row whose source cannot be checked: refused.
    rows, msgs = [], []
    for to in (100, 1):
        got, msg = ladder_model.model(res, os.path.join(res, "levers.tsv"), "S0-T1", 10, to, "@PRJTEST:1-2", "test")
        rows += got
        msgs.append(msg)
    with open(os.path.join(res, "g3", "ladder-modelled.tsv"), "w") as f:
        f.write("\t".join(ladder_model.HEAD) + "\n")
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
        if variant == "handrow":
            # The reviewer's case: a hand-entered value citing a real file with its real sha256.
            import hashlib
            sha = hashlib.sha256(open(os.path.join(res, "levers.tsv"), "rb").read()).hexdigest()
            f.write("\t".join(["S", "S0-T1", "100", "wall_s", "99999", "hand", "10", "@PRJTEST:1-2", rows[0][8],
                               f"by hand | results/levers.tsv={sha}"]) + "\n")
            f.write("S\tS0-Tv\t10\twall_s\t999\thand\t10\t@PRJTEST:1-2\tx\tmy notes | results/g3/x/rates.tsv="
                    + "0" * 64 + "\n")
    if variant == "recorded":
        # A launch refused before any sample (as InsufficientInstanceCapacity leaves it): 0 of 1 samples.
        single(res, "20261010-000099-aaaaaaa", "S", "S0-T1", 9, 50, samples=[])
        # A run with a sample record but incomplete (1 of 2 planned): no refused launch.
        single(res, "20261010-000098-aaaaaaa", "S", "S0-T1", 8, 60, accessions=("SRR1", "SRR2"), samples=[sample("S", "S0-T1")])
    if variant == "stale":
        # A third c10 run after the model was written: the model is stale (its run set changed).
        single(res, "20261010-000024-aaaaaaa", "S", "S0-T1", 3, 3200, cohort=10, accessions=("SRR1", "SRR2"),
               samples=[sample("S", "S0-T1", acc="SRR1", classify=1100.0, cohort=10, t0=T0 + 500),
                        sample("S", "S0-T1", acc="SRR2", classify=1100.0, cohort=10, t0=T0 + 1600)])
    return msgs


def run(variant="", recorded=None):
    """RECORDED: {run id: class} written as the run's g3_defects.tsv (none by default: the real one is
    never read here)."""
    tmp = tempfile.mkdtemp(prefix="ladder-test-")
    res = os.path.join(tmp, "results")
    msgs = record(res, variant)
    out = os.path.join(tmp, "out")
    rec = os.path.join(tmp, "g3_defects.tsv")
    if recorded:
        with open(rec, "w") as f:
            f.write("run\tclass\tevidence\n" + "".join(f"{k}\t{v}\tsynthetic (unit test)\n" for k, v in recorded.items()))
    rc = lt.main(["--results", res, "--levers", os.path.join(res, "levers.tsv"), "--out", out,
                  "--resolved", os.path.join(res, "resolved.tsv"), "--recorded", rec])
    T = {}
    for n in os.listdir(out):
        if n.endswith(".tsv"):
            with open(os.path.join(out, n)) as f:
                T[n] = list(csv.DictReader(f, delimiter="\t"))
    with open(os.path.join(out, "manifest.json")) as f:
        T["manifest"] = json.load(f)
    with open(os.path.join(out, "summary.md")) as f:
        T["summary"] = f.read()
    T["model_msgs"] = msgs
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
    check("ladder runs found (19: the no-params dir ignored, the cohort counted once)", len(runs), 19)
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
    check("modelled c100 row (median of 5000 and 5200): basis flagged, n 1",
          (g.get("basis", "")[:18], g.get("n"), g.get("median")), ("modelled (flagged)", "1", "5100.000000"))
    g = one(T["rungs.tsv"], rung="S0-T1", axis="billed_usd", cohort=100)
    check("modelled c100 billed (5.0, 5.2)", g.get("median"), 5.1)
    # Net: A's lad-net critical 100 s, of which its samples' sha-critical 10 + 10 = 20 s is in-sample. Net wall
    # 2900; fixed part 2900 - 2000 + 20 = 920; per-sample net 2000 - 20 = 1980, x 4000/2000 pairs = 3960: 4880.
    # B carries no in-sample share: 3100 - 2100 + 2100 x 2 = 5200 (measurement fixed at c10). Median 5040.
    # Net billed prorated: 5.0 x 4880/5000 = 4.88, 5.2 x 5200/5200 = 5.2 -> 5.04.
    g = one(T["rungs.tsv"], rung="S0-T1", axis="wall_net_s", cohort=100)
    check("modelled c100 net wall (4880, 5200)", (g.get("median"), g.get("basis", "")[:18]), ("5040.000000", "modelled (flagged)"))
    check("net basis: A's in-sample share scaled, B's measurement fixed",
          ("in-sample measurement scaled by P_target/P on 20261010-000020-aaaaaaa (20.000 s)" in g.get("basis", ""),
           "measurement treated as fixed at its c10 value on 20261010-000021-aaaaaaa" in g.get("basis", "")), (True, True))
    g = one(T["rungs.tsv"], rung="S0-T1", axis="billed_net_usd", cohort=100)
    check("modelled c100 net billed, prorated (4.88, 5.2)", g.get("median"), 5.04)
    d = one(T["deltas.tsv"], rung="S0-Tv", axis="wall_net_s", cohort=100)
    check("net delta on the modelled value (3005 - 5040), flagged", (d.get("delta"), d.get("status")),
          ("-2035.000000", "modelled (flagged): not a measurement, not resolvable"))
    check("summary: net comes from each node's lad-net number", "lad-net critical_measurement_s" in T["summary"], True)
    g = one(T["rungs.tsv"], rung="S0-T1", axis="wall_s", cohort=1)
    check("the c1 model is ignored: c1 stays measured", (g.get("basis"), g.get("median")), ("measured", "1005.000000"))
    check("note: modelled row ignored because measured runs exist",
          "modelled S0-T1 c1 wall_s ignored: measured runs exist" in T["manifest"]["notes"], True)
    src = one(T["rungs.tsv"], rung="S0-T1", axis="wall_s", cohort=100).get("basis", "")
    check("modelled source cites the c10 runs and their manifests' sha256",
          ("20261010-000020-aaaaaaa, 20261010-000021-aaaaaaa" in src, "g3/20261010-000020-aaaaaaa/manifest.json=" in src,
           "results/cohort/PRJTEST/runs.tsv=" in src), (True, True, True))
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
          ("0.000000", "2.000000", "unresolvable: below instrument granularity (against the nearest run ancestor S2 "
                                   "(S3 not-run: no parameter change (the tune probe chose none)))"))
    d = one(T["deltas.tsv"], rung="O1", axis="billed_usd", cohort=1)
    check("O1 billed -0.099, threshold 2 x max(0.004, 0.002, 0.004)", (d.get("delta"), d.get("threshold"), d.get("status")),
          ("-0.099000", "0.008000", "resolved"))
    d = one(T["deltas.tsv"], rung="S0-Tv", axis="wall_s", cohort=100)
    check("a delta on modelled values is flagged, not resolved (3005 - 5100)", (d.get("delta"), d.get("status")),
          ("-2095.000000", "modelled (flagged): not a measurement, not resolvable"))
    # Gross and net (Scott, 2026-10-10): S2's lad-net critical_measurement_s 30 and 90 s: net walls 370, 320
    # (median 345, range 50); net billed prorated 0.4 x 370/400 = 0.370, 0.41 x 320/410 = 0.320 (median 0.345).
    g = one(T["rungs.tsv"], rung="S2", axis="wall_net_s", cohort=1)
    check("S2 net wall: median, range, q (2 s + 1 ms), series",
          (g.get("median"), g.get("range"), g.get("granularity_q"), g.get("series")),
          ("345.000000", "50.000000", "2.001000", "net (headline)"))
    g = one(T["rungs.tsv"], rung="S2", axis="billed_net_usd", cohort=1)
    check("S2 net billed, prorated", (g.get("median"), g.get("series")), ("0.345000", "net (prorated; headline)"))
    r = one(runs, run_id="20261010-000008-aaaaaaa")
    check("runs.tsv: the lad-net components", r.get("net_components"), "r0=identity:90.000,sha_get:0.000,sha_critical:0.000")
    check("runs.tsv: gross 410, net 320 from the node's lad-net (r0=90)",
          (r.get("wall_s"), r.get("wall_net_s"), r.get("critical_measurement_s"), r.get("net_basis")),
          ("410.0", "320.000", "r0=90.000", lt.NET_BASIS))
    dg = one(T["deltas.tsv"], rung="S2", axis="wall_s", cohort=1)
    dn = one(T["deltas.tsv"], rung="S2", axis="wall_net_s", cohort=1)
    check("the resolution check runs on each series separately: gross -175 (threshold 80), net -235 (threshold 100)",
          ((dg.get("delta"), dg.get("threshold"), dg.get("series")), (dn.get("delta"), dn.get("threshold"), dn.get("series"))),
          (("-175.000000", "80.000000", "gross"), ("-235.000000", "100.000000", "net (headline)")))
    # Pairs.
    P = T["pairs.tsv"]

    def pair(name, src, ax):
        rows = [x for x in P if x["pair"] == name and x["source"] == src and x["axis"] == ax and x["cohort"] == "1"]
        return [float(x["delta"]) for x in rows if x["row"] == "lever"], next((x for x in rows if x["row"] == "total"), {})
    lev, tot = pair("S vs O*", "S0-T1", "wall_net_s")
    check("S vs O* net (headline): S2's step is -235, O0's +44 against S2's net; total = sum", (lev, tot.get("delta"),
          tot.get("sum_of_lever_deltas"), tot.get("series")),
          ([-395.0, -30.0, -235.0, -44.0, -99.0], "-803.000000", "-803.000000", "net (headline)"))
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
    t = one(P, pair="S vs S*", source="S0-T1", axis="wall_s", cohort=100, row="total")
    check("c100 S vs S* from the modelled S0-T1: flagged, and the note says the source is modelled",
          (t.get("delta"), t.get("status"), t.get("note")),
          ("-2095.000000", "modelled (flagged): not a measurement, not resolvable",
           "totals: target from ladder runs, source from a modelled value (flagged: not a measurement); residual is an "
           "identity (both totals are the values the lever rows use, so the deltas telescope)"))
    check("note: a cold endpoint run on an undeclared rung",
          any(n.startswith("20261010-000019-aaaaaaa: cold endpoint run for S*-time at c1 is on S1, but ladder.levers.tsv "
                           "declares S2") for n in T["manifest"]["notes"]), True)
    # Law 1 and S5.
    l1 = one(T["law1.tsv"], accession="SRR1")
    check("Law 1 identical across arms, stock reference", (l1.get("status"), l1.get("reference")),
          ("identical", "20261010-000001-aaaaaaa (S0-T1)"))
    s5 = [(x["run_id"], x["s5_fallback"], x["rg_sha256"], x["law1_status"], x["s5_check"]) for x in T["s5-nonpreserving.tsv"]]
    check("S5 rows: the gzip fallback, compared normally", s5,
          [("20261010-000008-aaaaaaa", "gzip", RG1, "identical", "S rapidgzip output")])
    check("S5 fallback run in the attribution", one(runs, run_id="20261010-000008-aaaaaaa").get("in_attribution"), "yes")
    check("summary: the finding against the lever (1 of 1 input)",
          "S2: S5 not output-preserving on 1 of 1 inputs (fell back to gzip): SRR1" in T["summary"], True)
    check("summary: lever rows under a pair total", "| | | | | | | lever 3 | S2 (rapidgzip) | -175.000000 | resolved |" in T["summary"],
          True)
    check("summary: endpoint basis column", "| endpoint basis |" in T["summary"], True)
    # Endpoint rows.
    ep = T["endpoints.tsv"]
    check("endpoint cold and warm walls", (one(ep, state="cold", rung="S2", metric="wall_s").get("median"),
                                           one(ep, state="warm", metric="wall_s").get("median")), ("420.000000", "380.000000"))
    # S3 is marked not-run (no parameter change): O0's delta is against the nearest run ancestor, S2.
    d = one(T["deltas.tsv"], rung="O0", axis="wall_s", cohort=1)
    check("O0 against the nearest run ancestor S2 (S3 not run), labelled",
          (d.get("predecessor"), d.get("delta"), d.get("predecessor_basis"), d.get("status")),
          ("S2", "-104.000000", "nearest run ancestor S2 (S3 not-run: no parameter change (the tune probe chose none))",
           "resolved (against the nearest run ancestor S2 (S3 not-run: no parameter change (the tune probe chose none)))"))
    d = one(T["deltas.tsv"], rung="S3", axis="wall_s", cohort=1)
    check("S3's own row says not run", (d.get("status"), d.get("delta")),
          ("not-run: no parameter change (the tune probe chose none)", ""))
    lev = [x for x in T["pairs.tsv"] if x["pair"] == "S* vs O*" and x["axis"] == "wall_s" and x["cohort"] == "1"
           and x["row"] == "lever"]
    check("pairs skip S3 and label O0's step", [(x["rung"], x["predecessor"], x["note"][:39]) for x in lev],
          [("O0", "S2", "against the nearest run ancestor S2 (S3"), ("O1", "O0", "")])
    check("endpoint warm classify phase", one(ep, state="warm", metric="phase.classify").get("median"), 20.0)
    # Spend and the manifest.
    sp = T["spend.tsv"]
    check("spend: in / not in the campaign spend.tsv", (one(sp, run_id="20261010-000001-aaaaaaa").get("in_campaign_spend"),
          one(sp, run_id="20261010-000002-aaaaaaa").get("in_campaign_spend")), ("yes", "NO"))
    # 1.000+1.010+0.600+0.620+0.560+0.600+0.400+0.410+0.300+0.302+0.200+0.204+0.420+0.380 = 7.006,
    # + 0.333 (000019) + 3.000 + 3.100 (c10) + 3.000 + 3.010 (c100) = 19.449
    check("spend total", one(sp, run_id="TOTAL").get("billed_usd"), 19.449)
    man = T["manifest"]
    paths = [i["path"] for i in man["inputs"]]
    check("manifest cites levers, modelled, runs.tsv and every ladder manifest (not the non-ladder one)",
          (any(p.endswith("levers.tsv") for p in paths), any(p.endswith("ladder-modelled.tsv") for p in paths),
           any(p.endswith("PRJTEST/runs.tsv") for p in paths), sum(p.endswith("manifest.json") for p in paths),
           any("000016" in p for p in paths)), (True, True, True, 20, False))


def recorded_defects():
    """A run recorded in g3_defects.tsv is excluded once, as a recorded defect; its contract and
    incomplete checks raise no DEFECT and do not set the exit code; Law 1 is never suppressed."""
    rid = "20261010-000099-aaaaaaa"
    rc, T = run("recorded")
    check("unrecorded: the refused launch is an incomplete DEFECT, exit 1 (the probe resolves the effect)",
          (rc, "DEFECT (incomplete)" in one(T["runs.tsv"], run_id=rid).get("in_attribution", "")), (1, True))
    rc, T = run("recorded", {rid: "capacity: InsufficientInstanceCapacity (synthetic)", "20261010-000098-aaaaaaa": "defect: synthetic"})
    check("recorded: exit 0, and DEFECTs: 0 in summary.md", (rc, "- DEFECTs: 0" in T["summary"]), (0, True))
    check("recorded: excluded once, as the recorded defect", one(T["runs.tsv"], run_id=rid).get("in_attribution"),
          "no: recorded defect (capacity): excluded")
    check("recorded: the summary reports it once, as the recorded defect, and in no DEFECT line",
          (T["summary"].count(f"{rid}: recorded defect (capacity): excluded"), sum(rid in l and "DEFECT" in l for l in T["summary"].splitlines())), (1, 0))
    # The guard: recorded as capacity, but it has sample records (no refused launch): its incomplete
    # DEFECT is raised again, with a DEFECT (recorded) naming the mismatch. Recorded as another class
    # (a failed run may have samples), it stays suppressed.
    cap = {rid: "capacity: synthetic", "20261010-000098-aaaaaaa": "capacity: synthetic"}
    rc, T = run("recorded", cap)
    ia = one(T["runs.tsv"], run_id="20261010-000098-aaaaaaa").get("in_attribution", "")
    check("guard: capacity with a sample record: exit 1, its incomplete DEFECT raised again and the mismatch named",
          (rc, "DEFECT (incomplete)" in ia, "with 1 sample record(s)" in ia, "recorded as capacity in g3_defects.tsv" in T["summary"],
           "recorded defect (capacity): excluded" in ia), (1, True, True, True, False))
    rc, T = run("recorded", {rid: "capacity: synthetic", "20261010-000098-aaaaaaa": "defect: synthetic (a failed run)"})
    check("guard: the same run recorded as a defect (not capacity) stays suppressed: exit 0",
          (rc, one(T["runs.tsv"], run_id="20261010-000098-aaaaaaa").get("in_attribution")), (0, "no: recorded defect (defect): excluded"))
    rc, T = run("sha", {"20261010-000010-aaaaaaa": "defect: synthetic"})
    check("recorded, but its output differs from stock: the Law 1 DEFECT still stands, exit 1",
          (rc, one(T["law1.tsv"], accession="SRR1").get("status"),
           "DEFECT (Law 1)" in one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution", "")), (1, "DEFECT", True))


def variants():
    recorded_defects()
    rc, T = run("sha")
    check("sha mismatch exits 1", rc, 1)
    check("sha mismatch: DEFECT", one(T["law1.tsv"], accession="SRR1").get("status"), "DEFECT")
    check("detail names the role", one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa", role="output").get("status"),
          "DEFECT: sha256 differs from the reference on output")
    check("a Law 1 DEFECT excludes its run", one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution"),
          "no: DEFECT (Law 1): SRR1: sha256 differs from the reference on output")
    check("O0 n drops to 1 without it", one(T["rungs.tsv"], rung="O0", axis="wall_s", cohort=1).get("n"), "1")
    rc, T = run("fileset")
    check("file-set mismatch exits 1", rc, 1)
    check("detail names the extra file", one(T["law1-detail.tsv"], run_id="20261010-000010-aaaaaaa",
                                             role="classified_1").get("status"),
          "DEFECT: file set differs from the reference (missing -; extra classified_1)")
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
    check("O-arm s5 differs with an S entry of the same rg_sha256: exit 0", rc, 0)
    d = one(T["s5-nonpreserving.tsv"], run_id="20261010-000010-aaaaaaa")
    check("O-arm s5 differs: matched by rg_sha256, outputs compared normally", (d.get("s5_check"), d.get("law1_status")),
          ("rg_sha256 matches the S entry 20261010-000008-aaaaaaa", "identical"))
    check("O-arm fallback run stays in the attribution",
          one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution"), "yes")
    rc, T = run("o5none")
    check("O-arm s5 differs with no S entry of that rg_sha256: exit 1", rc, 1)
    check("O-arm s5 differs with no match: DEFECT, run excluded",
          (one(T["law1.tsv"], accession="SRR1").get("status"),
           one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution")),
          ("DEFECT", "no: DEFECT (Law 1): SRR1: O-arm s5 differs and no S entry has the same rg_sha256"))
    rc, T = run("o5crash")
    check("O-arm rapidgzip crash with a gzip fallback: not a DEFECT (exit 0)", rc, 0)
    d = one(T["s5-nonpreserving.tsv"], run_id="20261010-000010-aaaaaaa")
    check("O-arm crash: labelled, not compared by rg_sha256; outputs compared normally", (d.get("s5_check"), d.get("law1_status")),
          ("rapidgzip crashed (exit 139); fell back to gzip: not compared by rg_sha256", "identical"))
    check("O-arm crash run stays in the attribution", one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution"), "yes")
    check("O-arm crash is a finding against the lever",
          any(f.startswith("O0: rapidgzip crashed on 1 of ") and "SRR1 in 20261010-000010-aaaaaaa (exit 139)" in f
              for f in T["manifest"]["findings"]), True)
    rc, T = run("o5crashmate")
    check("crash on mate 1, a deterministic difference on mate 2: the rg_sha256 rule applies (DEFECT, exit 1)",
          (rc, one(T["runs.tsv"], run_id="20261010-000010-aaaaaaa").get("in_attribution")),
          (1, "no: DEFECT (Law 1): SRR1: O-arm s5 differs and no S entry has the same rg_sha256"))
    rc, T = run("o5crashout")
    check("crash with the gzip fallback but a kraken2 output mismatch: Law 1 DEFECT (exit 1)",
          (rc, one(T["law1.tsv"], accession="SRR1").get("status")), (1, "DEFECT"))
    rc, T = run("s5none")
    check("s5 differs without a gzip fallback: contract DEFECT, exit 1", rc, 1)
    check("s5 differs without a fallback: excluded",
          one(T["runs.tsv"], run_id="20261010-000013-aaaaaaa").get("in_attribution"), "no: DEFECT (contract) in its lad-sample lines")
    rc, T = run("rgdisagree")
    check("S entries disagreeing on rg_sha256: flagged, not a DEFECT (exit 0)", rc, 0)
    check("rg_sha256 disagreement is a finding", any("SRR1: S-arm s5 differs entries disagree on rg_sha256 (2 distinct" in f
                                                     for f in T["manifest"]["findings"]), True)
    check("finding: 2 of 2 S2 inputs? no: 1 accession fell back", "S2: S5 not output-preserving on 1 of 1 inputs" in T["summary"], True)
    # H: a cohort member that never launched, and the planned set from cohort.json.
    rc, T = run("missingmember")
    check("missing member manifest: exit 1", rc, 1)
    check("missing member manifest: DEFECT incomplete, excluded",
          one(T["runs.tsv"], run_id="20261010-000011-aaaaaaa-1234-n2").get("in_attribution"),
          "no: DEFECT (incomplete): cohort member manifest missing: rank 1")
    check("O1 n drops to 1 without it", one(T["rungs.tsv"], rung="O1", axis="wall_s", cohort=1).get("n"), "1")
    rc, T = run("cohortref")
    check("cohort.json's planned set, not the members': exit 1", rc, 1)
    check("cohort.json's planned set (@PRJTEST:1-2): incomplete",
          one(T["runs.tsv"], run_id="20261010-000011-aaaaaaa-1234-n2").get("in_attribution"),
          "no: DEFECT (incomplete): 1 of 2 planned samples; missing SRR2")
    rc, T = run("handrow")
    check("hand-entered modelled rows: exit 1", rc, 1)
    dd = T["manifest"]["defects"]
    check("the reviewer's case (99999, citing a real file's real sha256) is refused by re-derivation",
          "modelled: refused: ladder-modelled.tsv row 10 (S0-T1 c100 wall_s): value 99999 but the model gives 5100.000 on "
          "the current record" in dd, True)
    check("a row citing a file that does not exist is refused",
          "modelled: refused: ladder-modelled.tsv row 11 (S0-Tv c10 wall_s): source not checkable: results/g3/x/rates.tsv "
          "does not exist" in dd, True)
    check("refused rows not used: c100 stays 5100, no S0-Tv c10 row",
          (one(T["rungs.tsv"], rung="S0-T1", axis="wall_s", cohort=100).get("median"),
           [x for x in T["rungs.tsv"] if x["rung"] == "S0-Tv" and x["cohort"] == "10"]), ("5100.000000", []))
    rc, T = run("stale")
    check("a stale model (a new c10 run since): exit 1", rc, 1)
    check("stale model refused: its run set is not what the model uses now",
          any("cites runs 20261010-000020-aaaaaaa,20261010-000021-aaaaaaa but the model would use "
              "20261010-000020-aaaaaaa,20261010-000021-aaaaaaa,20261010-000024-aaaaaaa now" in d for d in T["manifest"]["defects"]),
          True)
    check("stale rows not used", [x for x in T["rungs.tsv"] if x["rung"] == "S0-T1" and x["cohort"] == "100"], [])
    rc, T = run("fneg")
    check("model refused when S > wall (F < 0)", T["model_msgs"][0],
          "refused: 20261010-000021-aaaaaaa: per-sample span S 3200.000 s > wall 3100.0 s (fixed part F = -100.000 s < 0)")
    check("no modelled c100 row then", [x for x in T["rungs.tsv"] if x["rung"] == "S0-T1" and x["cohort"] == "100"], [])
    rc, T = run("alias")
    check("alias variant exits 0", rc, 0)
    g = one(T["rungs.tsv"], rung="Sstar-time", axis="wall_s", cohort=1)
    check("an alias rung reads its winner's runs (S2 at c1)", (g.get("n"), g.get("median"), g.get("basis")),
          ("2", "405.000000", "alias of S2 (ladder.resolved.tsv; source results/g3/20261010-000007-aaaaaaa)"))
    g = one(T["rungs.tsv"], rung="Sstar-time", axis="wall_s", cohort=10)
    check("an unresolved alias says so, never a silent empty", (g.get("n"), g.get("basis")),
          ("0", "alias unresolved: no ladder.resolved.tsv row (key alias)"))
    check("note: unresolved at c100 although a candidate has runs there",
          "Sstar-time is unresolved at c100 although its candidates S0-Tv have runs there (alias unresolved: no "
          "ladder.resolved.tsv row (key alias))" in T["manifest"]["notes"], True)
    d = one(T["deltas.tsv"], rung="Sstar-time", axis="wall_s", cohort=10)
    check("its delta: alias unresolved", d.get("status"), "alias unresolved")
    d = one(T["deltas.tsv"], rung="Sstar-time", axis="wall_s", cohort=1)
    check("an alias of its own predecessor adds no lever", (d.get("delta"), d.get("status")),
          ("", "Sstar-time is an alias of its predecessor S2: no lever"))
    d = one(T["deltas.tsv"], rung="O0", axis="wall_s", cohort=1)
    check("O0 against the alias = against S2's runs", (d.get("predecessor"), d.get("delta")), ("Sstar-time", "-104.000000"))
    lev = [(x["rung"], x["delta"]) for x in T["pairs.tsv"] if x["pair"] == "S vs O*" and x["source"] == "S0-T1"
           and x["axis"] == "wall_s" and x["cohort"] == "1" and x["row"] == "lever"]
    check("pairs skip the alias step (no lever) and keep the sum",
          lev, [("S0-Tv", "-395.000000"), ("S1", "-30.000000"), ("S2", "-175.000000"), ("O0", "-104.000000"),
                ("O1", "-99.000000")])
    rc, T = run("nonet")
    check("a run without lad-net: exit 0", rc, 0)
    r = one(T["runs.tsv"], run_id="20261010-000005-aaaaaaa")
    check("without lad-net: net missing with a note, gross kept in the attribution",
          (r.get("wall_net_s"), r.get("wall_s"), r.get("in_attribution"),
           "net missing (not imputed): rank 0: no lad-net line" in r.get("notes", "")), ("", "560.0", "yes", True))
    check("S1 net n drops to 1, gross stays 2", (one(T["rungs.tsv"], rung="S1", axis="wall_net_s", cohort=1).get("n"),
                                                   one(T["rungs.tsv"], rung="S1", axis="wall_s", cohort=1).get("n")), ("1", "2"))
    rc, T = run("badnet")
    check("a malformed lad-net line: exit 1", rc, 1)
    check("malformed lad-net: contract DEFECT, excluded", one(T["runs.tsv"], run_id="20261010-000005-aaaaaaa").get("in_attribution"),
          "no: DEFECT (contract): 20261010-000005-aaaaaaa 20261010-000005-aaaaaaa: lad-net: rank 7 is not the node's rank 0")
    rc, T = run("critbig")
    check("critical_measurement_s beyond the node's window: exit 1", rc, 1)
    check("... a contract DEFECT, the run excluded", one(T["runs.tsv"], run_id="20261010-000005-aaaaaaa").get("in_attribution"),
          "no: DEFECT (contract): 20261010-000005-aaaaaaa 20261010-000005-aaaaaaa: lad-net: critical_measurement_s 600.000 "
          "exceeds the node's window 560.000 s (terminated_at - launch_time)")
    rc, T = run("aliasbad")
    check("resolved: a winner outside alias_of and a duplicate row: exit 1", rc, 1)
    dd = T["manifest"]["defects"]
    check("both are DEFECTs", ("resolved: ladder.resolved.tsv: Sstar-time at c10 names 'S9', not one of its alias_of S2|S1|S0-Tv" in dd,
                               "resolved: ladder.resolved.tsv: Sstar-time at c1 resolved more than once" in dd), (True, True))
    check("the duplicated cohort is left unresolved", one(T["rungs.tsv"], rung="Sstar-time", axis="wall_s", cohort=1).get("basis"),
          "alias unresolved: Sstar-time at c1 has more than one ladder.resolved.tsv row")
    rc, T = run("gzfail")
    check("gzip failed in the identity phase: exit 1", rc, 1)
    check("... its own DEFECT (input or staging), the run excluded",
          one(T["runs.tsv"], run_id="20261010-000008-aaaaaaa").get("in_attribution"),
          "no: DEFECT (input): SRR1: input or staging failure: gzip exited [1]")
    check("... and not an S5 finding", any("fell back to gzip" in f for f in T["manifest"]["findings"]), False)
    rc, T = run("notruncohort")
    check("not_run_cohorts: exit 0", rc, 0)
    nr = "not-run at c1: the only candidate is S0-Tv's own configuration (not_run_cohorts)"
    d = one(T["deltas.tsv"], rung="S2", axis="wall_s", cohort=1)
    check("S2 at c1 against the nearest run ancestor S0-Tv (405 - 610)", (d.get("predecessor"), d.get("delta"),
          d.get("predecessor_basis")), ("S0-Tv", "-205.000000", f"nearest run ancestor S0-Tv (S1 {nr})"))
    d = one(T["deltas.tsv"], rung="S1", axis="wall_s", cohort=1)
    check("S1's own c1 row carries the label, no numbers", (d.get("status"), d.get("delta")), (nr, ""))
    check("S1 is not skipped at cohorts it does not list",
          [x for x in T["deltas.tsv"] if x["rung"] == "S1" and x["cohort"] == "100" and x["status"].startswith("not-run")], [])
    lev = [(x["rung"], x["delta"]) for x in T["pairs.tsv"] if x["pair"] == "S vs S*" and x["source"] == "S0-T1"
           and x["axis"] == "billed_usd" and x["cohort"] == "1" and x["row"] in ("lever", "total")]
    check("pairs skip S1 at c1 and keep the sum", lev, [("S0-Tv", "-0.395000"), ("S2", "-0.205000"), ("", "-0.600000")])
    check("a run on a not-run cohort gets a note",
          "is marked" in one(T["runs.tsv"], run_id="20261010-000005-aaaaaaa").get("notes", ""), True)
    rc, T = run("idline")
    check("input_defect on an identity line: exit 1", rc, 1)
    check("... an input DEFECT, the run excluded", one(T["runs.tsv"], run_id="20261010-000008-aaaaaaa").get("in_attribution"),
          "no: DEFECT (input): SRR1: input or staging failure: the identity line flags input_defect on SRR1_1.fastq.gz "
          "(gzip exit 0)")
    rc, T = run("idboth")
    check("flagged by both the sample's s5 and the identity line: one DEFECT",
          [d for d in T["manifest"]["defects"] if d.startswith("input: 20261010-000008-aaaaaaa")],
          ["input: 20261010-000008-aaaaaaa SRR1: input or staging failure: gzip exited [1]"])
    rc, T = run("overlap")
    check("model refused when 10 samples overlap (not a serial T1 run)", T["model_msgs"][0],
          "refused: 20261010-000025-aaaaaaa: samples overlap (union of spans 1000.000 s < their sum 10000.000 s - 1 ms x 10): "
          "not a serial T1 run")
    check("no modelled c100 row then", [x for x in T["rungs.tsv"] if x["rung"] == "S0-T1" and x["cohort"] == "100"], [])
    rc, T = run("c10law1")
    check("a c10 run with a Law 1 DEFECT: exit 1", rc, 1)
    check("it cannot feed the model: c100 from run A alone (5000)",
          one(T["rungs.tsv"], rung="S0-T1", axis="wall_s", cohort=100).get("median"), 5000.0)
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
         "t_start": 5.0, "t_end": 6.0,
         "outputs": {"output": {"bytes": 1, "sha256": "zz"}}, "s5": {"status": "maybe"}, "_node": "r"}]}
    check("contract: rung mismatch, no report, bad sha, bad s5 (4 errors)", len(lt.contract_errors(bad)), 4)
    bad["samples"][0].update(rung="S1", outputs=GOOD, s5={"status": "n/a", "fallback": "gzip"})
    check("contract: fallback gzip without differs", lt.contract_errors(bad), ["r r X: s5.fallback gzip without s5.status differs"])
    b1 = lambda st, rg, gz, rx, gx: dict(status=st, fallback="gzip" if st == "differs" else "none", rg_sha256=rg,
                                         gz_sha256=gz, rg_exit=rx, gz_exit=gx)
    bad["samples"][0]["s5"] = b1("differs", [GZ], [GZ], [0], [0])
    check("B1: differs with equal lists, exits 0, nothing empty: rejected", lt.contract_errors(bad),
          ["r r X: s5.status differs, but the lists are equal, rapidgzip exits 0, gzip 0 or 2, and no output is empty"])
    bad["samples"][0]["s5"] = b1("differs", [GZ, GZ], [GZ, GZ], [0, 1], [0, 0])
    check("B1: differs with equal lists but rapidgzip exited 1 on mate 2: accepted", lt.contract_errors(bad), [])
    bad["samples"][0]["s5"] = b1("differs", [lt.EMPTY_SHA], [lt.EMPTY_SHA], [0], [0])
    check("B1: differs with equal lists but the empty-stream sha: accepted", lt.contract_errors(bad), [])
    # GNU gzip's exit 2 is a warning (trailing garbage ignored; the output is complete): not a difference by itself.
    bad["samples"][0]["s5"] = b1("identical", [GZ], [GZ], [0], [2])
    check("B1: identical with gzip exiting 2 (its warning) and equal outputs: accepted", lt.contract_errors(bad), [])
    bad["samples"][0]["s5"] = dict(b1("identical", [GZ], [GZ], [0], [2]), gz_warning=[True])
    check("B1: gz_warning true for gz_exit 2: accepted", lt.contract_errors(bad), [])
    bad["samples"][0]["s5"] = dict(b1("identical", [GZ], [GZ], [0], [2]), gz_warning=[False])
    check("contract: gz_warning must follow gz_exit 2", lt.contract_errors(bad),
          ["r r X: s5.gz_warning [False] must be, per mate, whether gz_exit is 2 ([2])"])
    bad["samples"][0]["s5"] = b1("identical", [GZ], [GZ], [0], [1])
    check("B1: identical with gzip exiting 1: rejected", lt.contract_errors(bad),
          ["r r X: s5.status identical, but the B1 rule says differs (sha256 lists, a non-zero rapidgzip exit, a gzip exit "
           "other than 0 or 2, or an empty-stream sha256)"])
    bad["samples"][0]["s5"] = b1("identical", [GZ], [GZ], [3], [0])
    check("B1: identical with rapidgzip exiting non-zero: rejected", len(lt.contract_errors(bad)), 1)
    check("gzip exit 2 with a full stream is not an input failure",
          lt.gzip_failed({"s5": {"status": "differs", "gz_exit": [2, 0], "gz_sha256": [GZ, GZ]}}), "")
    check("gzip exit 1 is an input failure",
          lt.gzip_failed({"s5": {"status": "differs", "gz_exit": [1, 0], "gz_sha256": [GZ, GZ]}}), "input or staging failure: gzip exited [1, 0]")
    check("gzip exit 2 with an empty stream is an input failure",
          lt.gzip_failed({"s5": {"status": "differs", "gz_exit": [2, 0], "gz_sha256": [lt.EMPTY_SHA, GZ]}}),
          "input or staging failure: gzip's output is the empty stream")
    bad["samples"][0]["s5"] = b1("identical", [GZ], [GZ], [0], [0])
    check("B1: identical, equal lists, exits 0: accepted", lt.contract_errors(bad), [])
    bad["samples"][0]["s5"] = dict(b1("identical", [GZ], [GZ], [0], [0]), rg_exit=["0"])
    check("B1: exits must be integer lists", lt.contract_errors(bad),
          ["r r X: s5.rg_exit and s5.gz_exit must be integer lists, one per mate"])
    # Net, per node (the interim rule): node A launch 0, terminated 100, critical 30 -> 70; node B launch 1,
    # terminated 90, critical 5 -> 85. Net = max(70, 85) - 0 = 85 (gross 100); billed 2 x 0.85 = 1.7.
    nd = lambda rid, rank, la, te, L: {"rid": rid, "rank": rank, "launch": la, "term": te, "lad_net": L}
    ok = lambda rank, c: [{"v": 1, "rank": rank, "critical_measurement_s": c}]
    run2 = {"run_id": "x", "wall_s": 100.0, "billed_usd": 2.0, "notes": [],
            "nodes_info": [nd("A", 0, 0.0, 100.0, ok(0, 30.0)), nd("B", 1, 1.0, 90.0, ok(1, 5.0))]}
    lt.net_components(run2)
    check("net = max over nodes of (terminated_at - critical_measurement_s) - first launch", run2["wall_net_s"], 85.0)
    check("net billed prorated", run2["billed_net_usd"], 1.7)
    check("net granularity: 2 s + 1 ms", lt.axis_value(dict(run2, price=3.6, nodes=2), "wall_net_s", {}, "x")[1], 2.001)
    run3 = dict(run2, notes=[], nodes_info=[nd("A", 0, 0.0, 100.0, ok(0, 30.0)), nd("B", 1, 1.0, 90.0, [])])
    lt.net_components(run3)
    check("a node without lad-net: net missing, not imputed, with a note",
          (run3["wall_net_s"], run3["billed_net_usd"], run3["notes"]),
          (None, None, ["net missing (not imputed): rank 1: no lad-net line"]))
    run4 = dict(run2, nodes_info=[nd("A", 0, 0.0, 100.0, [{"v": 1, "rank": 3, "critical_measurement_s": 1.0}]),
                                  nd("B", 1, 1.0, 90.0, ok(1, 5.0) + ok(1, 6.0)),
                                  nd("C", 2, 1.0, 90.0, [{"v": 1, "rank": 2, "critical_measurement_s": -1}])])
    check("lad-net contract: wrong rank, two lines, negative seconds", lt.lad_net_errors(run4),
          ["x A: lad-net: rank 3 is not the node's rank 0", "x B: lad-net: 2 lines (one per node)",
           "x C: lad-net: critical_measurement_s -1 is not seconds >= 0"])
    tmp = tempfile.mkdtemp(prefix="ladder-res-")
    with open(os.path.join(tmp, "r.tsv"), "w") as f:
        f.write("origin\tcohort\tkey\tvalue\tsource\nSstar-time\tc10\talias\tS7\tresults/x\n"
                "Sstar-time\t1\talias\tS9\tresults/y\n")
    res, errs = lt.load_resolved(os.path.join(tmp, "r.tsv"), lt.Reader(),
                                 {"Sstar-time": {"alias": True, "alias_of": ["S9", "Sstar-r8g"]}})
    shutil.rmtree(tmp)
    check("resolved: a winner outside alias_of is not a resolution, and a DEFECT; c-prefixed cohorts read",
          (res, errs), ({("Sstar-time", 10): (None, "alias unresolved: ladder.resolved.tsv names 'S7', not one of S9|Sstar-r8g"),
                         ("Sstar-time", 1): ("S9", "alias of S9 (ladder.resolved.tsv; source results/y)")},
                        ["ladder.resolved.tsv: Sstar-time at c10 names 'S7', not one of its alias_of S9|Sstar-r8g"]))
    # N-1, the reviewer's cases: critical_measurement_s beyond the node's own window.
    big = {"run_id": "x", "nodes_info": [nd("A", 0, 0.0, 150.0, ok(0, 500.0)), nd("B", 1, 1.0, 200.0, ok(1, 500.0))]}
    check("crit (500, 500) against windows (150, 199): two DEFECTs", lt.lad_net_errors(big),
          ["x A: lad-net: critical_measurement_s 500.000 exceeds the node's window 150.000 s (terminated_at - launch_time)",
           "x B: lad-net: critical_measurement_s 500.000 exceeds the node's window 199.000 s (terminated_at - launch_time)"])
    one_ = {"run_id": "y", "nodes_info": [nd("A", 0, 1.0, 200.0, ok(0, 300.0))]}
    check("crit 300 against a 199 s window: a DEFECT", lt.lad_net_errors(one_),
          ["y A: lad-net: critical_measurement_s 300.000 exceeds the node's window 199.000 s (terminated_at - launch_time)"])
    parts = lambda c, i, g, h: [{"v": 1, "rank": 0, "critical_measurement_s": c, "identity_s": i, "sha_get_s": g,
                                  "sha_critical_s": h}]
    check("lad-net components summing to critical_measurement_s (within 1 ms) are accepted",
          lt.lad_net_errors({"run_id": "z", "nodes_info": [nd("A", 0, 0.0, 200.0, parts(100.0, 60.0, 30.0, 10.0005))]}), [])
    check("components off by 2 ms: a DEFECT",
          lt.lad_net_errors({"run_id": "z", "nodes_info": [nd("A", 0, 0.0, 200.0, parts(100.0, 60.0, 30.0, 10.002))]}),
          ["z A: lad-net: identity_s + sha_get_s + sha_critical_s = 100.002 is not critical_measurement_s 100.000 (within 1 ms)"])
    check("a partial set of components: a DEFECT",
          lt.lad_net_errors({"run_id": "z", "nodes_info": [nd("A", 0, 0.0, 200.0,
                                                               [{"v": 1, "rank": 0, "critical_measurement_s": 5.0, "identity_s": 5.0}])]}),
          ["z A: lad-net: identity_s, sha_get_s, sha_critical_s must all be seconds >= 0 when any is given"])
    check("not_run_cohorts parses c-prefixed lists with reasons and bare lists",
          (lt.parse_cohort_list("c1: a; b;c10: x"), lt.parse_cohort_list("1;10"), lt.parse_cohort_list("")),
          ({1: "a; b", 10: "x"}, {1: "", 10: ""}, {}))
    check("crit equal to the window is allowed", lt.lad_net_errors({"run_id": "z", "nodes_info": [nd("A", 0, 1.0, 200.0, ok(0, 199.0))]}),
          [])
    check("an empty gzip stream is an input failure", lt.gzip_failed({"s5": {"status": "differs", "gz_exit": [0, 0],
                                                                              "gz_sha256": [GZ, lt.EMPTY_SHA]}}),
          "input or staging failure: gzip's output is the empty stream")
    bad["samples"][0]["s5"] = {"status": "identical", "rg_sha256": [GZ]}
    check("contract: rg/gz sha256 lists required", len(lt.contract_errors(bad)), 1)
    tmp = tempfile.mkdtemp(prefix="ladder-lv-")
    with open(os.path.join(tmp, "l.tsv"), "w") as f:
        f.write("rung\tarm\tpredecessor\tlever\tcounterpart\tstatus\n"
                "S3\tS\tS2\thosttune\tnot-run: in the wrong column\t\n"
                "S4\tS\tS3\tpxt\tO4\tnot-run: no parameter change\n")
    lv = lt.load_levers(os.path.join(tmp, "l.tsv"), lt.Reader())
    shutil.rmtree(tmp)
    check("not-run is read from the status column only", (lv["S3"]["not_run"], lv["S4"]["not_run"]),
          ("", "not-run: no parameter change"))
    check("union of sample spans", ladder_model.union_seconds([(0, 10), (5, 12), (20, 25)]), 17.0)
    ok, why = lt.check_source("x | a=b", "/nonexistent")
    check("check_source: a missing file is not checkable", (ok, why), (False, "a does not exist"))
    check("check_source: no file list", lt.check_source("results/g3/x/rates.tsv", "/")[0], False)
    bad["samples"][0].update(s5={"status": "n/a"}, t_end=4.0)
    check("contract: t_end before t_start", lt.contract_errors(bad),
          ["r r X: t_start and t_end must be epoch seconds with t_end >= t_start"])
    del bad["samples"][0]["t_start"]
    check("contract: t_start required", lt.contract_errors(bad), ["r r X: missing t_start"])
    # Compound lever phases, as ladder.levers.tsv writes them: each term carries its own scope.
    check("phase_parts: run:A+run:B term by term", lt.phase_parts("run:fetch-db+run:load+run:classify"),
          [("run", "fetch-db"), ("run", "load"), ("run", "classify")])
    check("phase_parts: mixed scopes and a bare term", lt.phase_parts("sample:sha+run:load+classify"),
          [("sample", "sha"), ("run", "load"), ("", "classify")])
    pr = {"phases_run": {"fetch-db": 30.0, "load": 20.0, "classify": 100.0}, "phase_entries": {"fetch-db": 1, "load": 1, "classify": 1},
          "samples": [{"phases": {"sha": 0.25}}, {"phases": {"sha": 0.5}}]}
    check("phase_value: run:fetch-db+run:load+run:classify sums the three", lt.phase_value(pr, "run:fetch-db+run:load+run:classify"),
          (150.0, 3 * lt.Q_RUN_PHASE))
    check("phase_value: sample:sha+run:load", lt.phase_value(pr, "sample:sha+run:load"), (20.75, lt.Q_RUN_PHASE + 2 * lt.Q_SAMPLE_PHASE))
    check("phase_missing: none for a measurable compound phase", lt.phase_missing(pr, "run:fetch-db+run:load+run:classify"), [])
    check("phase_missing: a term that matches nothing", lt.phase_missing(pr, "run:load+run:upload-drain+sample:nope"),
          ["run:upload-drain", "sample:nope"])
    # In the record: a run whose own lever phase matches nothing is a contract DEFECT and is excluded.
    tmp = tempfile.mkdtemp()
    res = os.path.join(tmp, "results")
    single(res, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000, {"setup": 5, "classify": 50})
    single(res, "20261010-000002-aaaaaaa", "S", "S1", 1, 600, {"setup": 5, "classify": 40})   # S1's phase is run:fetch-db
    with open(os.path.join(tmp, "l.tsv"), "w") as f:
        f.write(LEVERS)
    rd = lt.Reader()
    lv = lt.load_levers(os.path.join(tmp, "l.tsv"), rd)
    runs = lt.discover(res, rd)
    defects = []
    lt.validate(runs, lv, defects)
    shutil.rmtree(tmp)
    check("a run whose lever phase matches nothing: a contract DEFECT",
          [d for d in defects if "lever phase" in d[1]],
          [("contract", "20261010-000002-aaaaaaa: its lever phase run:fetch-db: run:fetch-db match(es) no manifest phase or lad-sample phase")])
    check("... and the run is excluded", any("lever phase" in e for r in runs if r["run_id"].endswith("02-aaaaaaa") for e in r["exclude"]), True)
    # A successor's phase on its predecessor run (NB1): an unconditional body phase missing there is a
    # DEFECT; a conditional one (identity, build-wait, sha-get), which the successor's lever may add, a note.
    tmp = tempfile.mkdtemp()
    res = os.path.join(tmp, "results")
    single(res, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000, {"setup": 5, "classify": 50})   # no fetch-db
    single(res, "20261010-000002-aaaaaaa", "S", "S0-Tv", 1, 900, {"setup": 5, "fetch-db": 9, "classify": 40})
    with open(os.path.join(tmp, "l.tsv"), "w") as f:
        f.write(LEVERS.replace("S0-Tv\tS\tS0-T1\tthreads\tO0\trun:classify", "S0-Tv\tS\tS0-T1\tthreads\tO0\trun:fetch-db+run:classify")
                .replace("S1\tS\tS0-Tv\ts5cmd-staging\tO0b\trun:fetch-db", "S1\tS\tS0-Tv\ts5cmd-staging\tO0b\trun:identity+run:fetch-db"))
    rd = lt.Reader()
    lv = lt.load_levers(os.path.join(tmp, "l.tsv"), rd)
    runs = lt.discover(res, rd)
    defects = []
    lt.validate(runs, lv, defects)
    shutil.rmtree(tmp)
    check("NB1: a successor's unconditional phase (fetch-db) missing on its predecessor run: a DEFECT",
          [d for d in defects if "predecessor run" in d[1]],
          [("contract", "20261010-000001-aaaaaaa: S0-Tv's lever phase run:fetch-db+run:classify: run:fetch-db not in this run "
                        "(its predecessor run), though the body marks it on every run")])
    # gz_warning (NB2): GNU gzip's exit 2 on S2's SRR1 mate 1: a summary note and tidy.tsv's s5.gz_warning name it.
    tmp2 = tempfile.mkdtemp()
    res2 = os.path.join(tmp2, "results")
    single(res2, "20261010-000001-aaaaaaa", "S", "S0-T1", 1, 1000, {"setup": 5, "classify": 50})
    gw = sample("S", "S2", s5="differs", fallback="gzip")
    gw["s5"]["gz_exit"], gw["s5"]["rg_exit"], gw["s5"]["gz_warning"] = [2], [1], [True]
    single(res2, "20261010-000002-aaaaaaa", "S", "S2", 1, 400, {"setup": 5, "classify": 50}, samples=[gw])
    with open(os.path.join(tmp2, "l.tsv"), "w") as f:
        f.write(LEVERS)
    rd2 = lt.Reader()
    T2, d2, notes2, _, _ = lt.build(lt.discover(res2, rd2), lt.load_levers(os.path.join(tmp2, "l.tsv"), rd2))
    shutil.rmtree(tmp2)
    th, trows = T2["tidy.tsv"]
    gwv = sorted((r[th.index("run_id")], r[th.index("value")]) for r in trows if r[th.index("metric")] == "s5.gz_warning")
    check("NB2: tidy.tsv s5.gz_warning names the mate (R1) on S2's sample, none on S0-T1's",
          gwv, [("20261010-000001-aaaaaaa", "none"), ("20261010-000002-aaaaaaa", "R1")])
    check("NB2: a summary note names it, and it is no input DEFECT",
          ([n for n in notes2 if n.startswith("gz_warning: ")], [d for d in d2 if d[0] == "input"]),
          (["gz_warning: 20261010-000002-aaaaaaa SRR1: GNU gzip exited 2 (its warning: trailing data ignored, the output "
            "complete) on R1; the input is kept, not an input defect"], []))
    n2 = [n for r in runs if r["run_id"].endswith("02-aaaaaaa") for n in r["notes"] if "conditional phase" in n]
    check("NB1: a conditional phase (identity) missing on the predecessor run: a note, not a DEFECT",
          (len(n2), any("20261010-000002" in d[1] for d in defects)), (1, False))


def main():
    base()
    variants()
    units()
    print(f"ladder_tables_test: {'FAIL ' + str(len(FAIL)) if FAIL else 'all ok'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
