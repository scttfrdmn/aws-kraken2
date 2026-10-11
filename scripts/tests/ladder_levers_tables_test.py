#!/usr/bin/env python3
"""make test (#51 x #52): the real scripts/g3/ladder.levers.tsv through #52's ladder_tables.py.

1. Its functions:
   - endpoints declared per cohort;
   - the two ladder-2 chains;
   - the stock rungs;
   - S3 not-run, with S4 <- S2a;
   - the rapidgzip lever;
   - the whole generator on an empty record (0 DEFECTs).
2. A synthetic record built with ladder_tables_test.py's own helpers:
   - every rung run at c1, n = 2, each rung 10 s faster than the rung its predecessor reads;
   - the aliases over candidate rungs (O2, O3 and their -cost copies) and the S* endpoints resolved
     in a real ladder.resolved.tsv, and the cost chain coinciding with the time chain through
     alias_cohorts (each declaration checked by the generator's alias_cohort_problems);
   - both S* vs O* pairs must follow their own chain, with 6 resolved lever rows each and a total
     equal to their sum; the cost chain's rows read the time chain's runs.
Run from the repo root (make test does)."""
import contextlib
import csv
import io
import os
import shutil
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
import ladder_levers as LL  # noqa: E402
import ladder_tables as lt  # noqa: E402
import ladder_tables_test as T  # noqa: E402

LEV = os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv")
ALIASES = ("Sstar-time", "Sstar-cost")
NF = 0


def check(what, ok):
    global NF
    print(("ok   " if ok else "FAIL ") + what)
    NF += 0 if ok else 1


def quiet_main(argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return lt.main(argv)


lv = lt.load_levers(LEV, lt.Reader())
m, errs = lt.declared_endpoints(lv)
check("no endpoint declaration errors", errs == [])
want = {"S*-time": "Sstar-time", "S*-cost": "Sstar-cost", "O*-time": "O5", "O*-cost": "O5-cost"}
check("each endpoint is declared on its rung at c1, c10, c100 and c1000",
      all({t: lt.endpoint_rung(m, t, c)[0] for t in want} == want for c in (1, 10, 100, 1000)))
check("the stock rungs are S0-T1 and S0-Tv", lt.stock_rungs(lv) == ["S0-T1", "S0-Tv"])
for top, root, other in (("O5", "Sstar-time", "Sstar-cost"), ("O5-cost", "Sstar-cost", "Sstar-time")):
    ch = lt.chain(lv, top)
    check("%s's chain reaches %s and S0-T1, not %s" % (top, root, other), root in ch and ch[-1] == "S0-T1" and other not in ch)
check("S3 is not run, and S4's run predecessor is S2a", lv["S3"]["not_run"].startswith("not-run") and lt.run_pred(lv, "S4") == ("S2a", []))
check("rapidgzip from S5 on (S5, Sstar-cost), not before (S4)",
      lt.has_rapidgzip(lv, "S5") and lt.has_rapidgzip(lv, "Sstar-cost") and not lt.has_rapidgzip(lv, "S4"))
check("S2d then S2c then S2a", lv["S2d"]["predecessor"] == "S2b-ii" and lv["S2c"]["predecessor"] == "S2d" and lv["S2c"]["lever"] == "IN_DEST" and lv["S2a"]["predecessor"] == "S2c")
check("the S* endpoints are aliases (read natively by the tables)", all(lv[a].get("alias") and not lv[a].get("not_run") for a in ALIASES))
check("S4 and S8 are not run at c1", all(1 in (lv[r].get("not_run_cohorts") or {}) for r in ("S4", "S8")))

tmp = tempfile.mkdtemp(prefix="ak2-lvtables-")
try:
    res, out = os.path.join(tmp, "empty"), os.path.join(tmp, "out0")
    os.makedirs(res)
    check("the generator on an empty record exits 0", quiet_main(["--results", res, "--levers", LEV, "--out", out]) == 0)

    # Every rung that runs at c1 gets 2 runs, each rung 10 s faster than the rung whose runs its
    # predecessor reads. Nothing stands in for the tables: S3 (not-run), the rungs not run at c1 (S4,
    # S8, O1, O4b and their candidates), the aliases and the alias_cohorts rungs get no runs. The
    # aliases resolve through a real ladder.resolved.tsv: both S* endpoints to Sstar-r8g, O2 to
    # O2-r8g, O2-cost to O2-cost-r8g, O3 to O3-n4 and O3-cost to O3-cost-n4. The cost chain then
    # coincides with the time chain from O0-cost to O5-cost, so a copy of the lever table declares the
    # rest of that coincidence (O3-cost-n4, O4a-cost, O5-cost) in alias_cohorts, and the generator's
    # check confirms every declaration on these resolutions.
    WIN = {"Sstar-time": "Sstar-r8g", "Sstar-cost": "Sstar-r8g", "O2": "O2-r8g", "O2-cost": "O2-cost-r8g",
           "O3": "O3-n4", "O3-cost": "O3-cost-n4"}
    EXTRA = {"O3-cost-n4": "O3-n4", "O4a-cost": "O4a", "O5-cost": "O5"}
    lev2 = os.path.join(tmp, "ladder.levers.tsv")
    lrows = LL.load(LEV)
    for r in lrows:
        if r["rung"] in EXTRA:
            r["alias_cohorts"] = "c1: " + EXTRA[r["rung"]]
    with open(lev2, "w") as f:
        f.write("\t".join(LL.COLS) + "\n" + "".join("\t".join(r[k] for k in LL.COLS) + "\n" for r in lrows))
    res = {(a, "1", "alias"): (w, "synthetic") for a, w in WIN.items()}
    check("the copy passes make ladder-check's table check", LL.check(lrows) == [])
    check("every alias_cohorts declaration at c1 is one configuration under these resolutions",
          LL.alias_cohort_problems(lrows, 1, res) == [] and all(LL.alias_at(r, 1) for r in lrows if r["rung"] in EXTRA))
    lv = lt.load_levers(lev2, lt.Reader())
    G = lt.Groups([], lv, {}, {}, [], {(a, 1): (w, "synthetic") for a, w in WIN.items()})
    depth = {}

    def d(r):
        if r not in depth:
            m, _ = G.alias(r, 1)
            if m != r:
                depth[r] = d(m)
            else:
                p, _ = lt.run_pred(lv, r, 1)
                depth[r] = 0 if not p else d(p) + 1
        return depth[r]

    res_dir, out, n = os.path.join(tmp, "synthetic"), os.path.join(tmp, "out1"), 0
    # Every phase the body marks, so each rung's lever phase (ladder.levers.tsv) is measurable.
    PH = {"setup": 5, "fetch-db": 10, "etag-hash.k2d": 1, "fetch-inputs": 3, "load": 20, "classify": 50, "upload-drain": 2}
    for r, x in lv.items():
        if x.get("not_run") or x.get("alias") or 1 in (x.get("not_run_cohorts") or {}) or 1 in (x.get("alias_cohorts") or {}):
            continue
        for rep in (1, 2):
            n += 1
            wall = 2000 - 10 * d(r) + (0.5 if rep == 2 else 0)
            s = T.sample(x["arm"], r, s5="identical" if lt.has_rapidgzip(lv, r) else "n/a")
            T.single(res_dir, "20261010-%06d-aaaaaaa" % n, x["arm"], r, rep, wall, PH, start=n * 3000, samples=[s])
    resd = os.path.join(tmp, "ladder.resolved.tsv")
    with open(resd, "w") as f:
        f.write("origin\tcohort\tkey\tvalue\tsource\n")
        for a, w in WIN.items():
            f.write("%s\t1\talias\t%s\tresults/g3/synthetic/tables/rungs.tsv\n" % (a, w))
    check("the synthetic record (%d runs; none for the not-run, alias and alias_cohorts rungs) gives no DEFECT" % n,
          quiet_main(["--results", res_dir, "--levers", lev2, "--resolved", resd, "--out", out]) == 0)
    rows = list(csv.DictReader(open(os.path.join(out, "pairs.tsv")), delimiter="\t"))
    lev = {}
    for fam, ax, src, tgt in (("time", "wall_s", "Sstar-time", "O5"), ("cost", "billed_usd", "Sstar-cost", "O5-cost")):
        rs = [r for r in rows if r["pair"] == "S* vs O*" and r["endpoint_axis"] == fam and r["axis"] == ax and r["cohort"] == "1"]
        tot = [r for r in rs if r["row"] == "total"]
        lev[fam] = [r for r in rs if r["row"] != "total"]
        ok = (len(tot) == 1 and tot[0]["source"] == src and tot[0]["target"] == tgt and len(lev[fam]) == 6
              and all(r["status"] == "resolved" for r in lev[fam])
              and abs(sum(float(r["delta"]) for r in lev[fam]) - float(tot[0]["delta"])) < 1e-6)
        check("S* vs O* (%s): %s -> %s, 6 resolved lever rows (O0, O0b, O2, O3, O4a, O5; O1 and O4b not run at c1) "
              "summing to the total" % (fam, src, tgt), ok)
    check("the cost chain's lever rows are the time chain's rungs' runs (alias_cohorts), one for one",
          [r["rung"] for r in lev["cost"]] == ["O0-cost", "O0b-cost", "O2-cost", "O3-cost", "O4a-cost", "O5-cost"]
          and [r["rung"] for r in lev["time"]] == ["O0", "O0b", "O2", "O3", "O4a", "O5"])
    rr = {(r["rung"], r["axis"]): r for r in csv.DictReader(open(os.path.join(out, "rungs.tsv")), delimiter="\t") if r["cohort"] == "1"}
    check("O0b-cost reads O0b's runs, labelled alias: same configuration as O0b at c1",
          rr[("O0b-cost", "wall_s")]["median"] == rr[("O0b", "wall_s")]["median"]
          and "alias: same configuration as O0b at c1" in rr[("O0b-cost", "wall_s")]["basis"])
    check("S4 (an alias over candidate rungs) is not run at c1, and S5 is measured against S2a",
          any(r["rung"] == "S5" and r["predecessor"] == "S2a" and r["cohort"] == "1"
              for r in csv.DictReader(open(os.path.join(out, "deltas.tsv")), delimiter="\t")))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print("ladder_levers_tables_test: %d failure(s)" % NF)
sys.exit(1 if NF else 0)
