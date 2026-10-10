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
   - every run rung of both chains at c1, n = 2, each rung 10 s faster than its run predecessor;
   - both S* vs O* pairs must follow their own chain, with 8 resolved lever rows each and a total
     equal to their sum.
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

    # Every rung that runs at c1 gets 2 runs, each rung 10 s faster than its run predecessor.
    # Nothing stands in for the tables: S3 (not-run), S4 and S8 (not run at c1) and the alias
    # endpoints get no runs. The aliases resolve through a real ladder.resolved.tsv: Sstar-time to
    # Sstar-r8g, Sstar-cost to Sstar-r8gd, so the two ladder-2 chains start from different winners.
    WIN = {"Sstar-time": "Sstar-r8g", "Sstar-cost": "Sstar-r8gd"}
    depth = {}

    def d(r):
        if r not in depth:
            if r in WIN:
                depth[r] = d(WIN[r])
            else:
                p, _ = lt.run_pred(lv, r, 1)
                depth[r] = 0 if not p else d(p) + 1
        return depth[r]

    res, out, n = os.path.join(tmp, "synthetic"), os.path.join(tmp, "out1"), 0
    for r, x in lv.items():
        if x.get("not_run") or x.get("alias") or 1 in (x.get("not_run_cohorts") or {}):
            continue
        for rep in (1, 2):
            n += 1
            wall = 2000 - 10 * d(r) + (0.5 if rep == 2 else 0)
            s = T.sample(x["arm"], r, s5="identical" if lt.has_rapidgzip(lv, r) else "n/a")
            T.single(res, "20261010-%06d-aaaaaaa" % n, x["arm"], r, rep, wall, start=n * 3000, samples=[s])
    resd = os.path.join(tmp, "ladder.resolved.tsv")
    with open(resd, "w") as f:
        f.write("origin\tcohort\tkey\tvalue\tsource\n")
        for a, w in WIN.items():
            f.write("%s\t1\talias\t%s\tresults/g3/synthetic/tables/rungs.tsv\n" % (a, w))
    check("the synthetic record (%d runs; no runs for S3, S4 and S8 at c1, or the aliases) gives no DEFECT" % n,
          quiet_main(["--results", res, "--levers", LEV, "--resolved", resd, "--out", out]) == 0)
    rows = list(csv.DictReader(open(os.path.join(out, "pairs.tsv")), delimiter="\t"))
    for fam, ax, src, tgt in (("time", "wall_s", "Sstar-time", "O5"), ("cost", "billed_usd", "Sstar-cost", "O5-cost")):
        rs = [r for r in rows if r["pair"] == "S* vs O*" and r["endpoint_axis"] == fam and r["axis"] == ax and r["cohort"] == "1"]
        tot = [r for r in rs if r["row"] == "total"]
        lev = [r for r in rs if r["row"] != "total"]
        ok = (len(tot) == 1 and tot[0]["source"] == src and tot[0]["target"] == tgt and len(lev) == 8
              and all(r["status"] == "resolved" for r in lev)
              and abs(sum(float(r["delta"]) for r in lev) - float(tot[0]["delta"])) < 1e-6)
        check("S* vs O* (%s): %s -> %s, 8 resolved lever rows summing to the total" % (fam, src, tgt), ok)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print("ladder_levers_tables_test: %d failure(s)" % NF)
sys.exit(1 if NF else 0)
