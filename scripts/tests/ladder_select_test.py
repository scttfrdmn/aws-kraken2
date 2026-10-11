#!/usr/bin/env python3
"""make ladder-select-test (in make test): scripts/lib/ladder_select.py on synthetic records.

Each case is a scratch repo root holding the real scripts/g3/ladder.levers.tsv and a synthetic
record built with ladder_tables_test.py's helpers: runs of the three S* candidates (S9,
Sstar-r8g, Sstar-r8gd) at c1, through the real ladder_tables.py. Synthetic data, unit test only
(Law 3). The cases:
  - resolved: S*-time to S9 by 100 s (threshold 4 s), S*-cost to Sstar-r8gd by $0.5 (billed set by
    hand, so the two axes disagree); margin `resolved`;
  - unresolvable: S9 by 2 s against a 4 s threshold: still S9, labelled unresolvable and "chosen by
    the registered rule from an unresolvable difference";
  - tie: equal medians, broken by fewer vCPUs (S9's x8g.24xlarge, 96, before 192);
  - the written rows pass ladder_levers' citation check and the tables read them (alias of the winner);
  - idempotent: a second run leaves the file byte for byte and writes no snapshot; a changed
    record replaces the row with a new snapshot; DRY_RUN writes nothing;
  - refusals (exit 3, nothing written): a candidate with n = 1; a Law 1 DEFECT in the record; a
    cited file changed since; RUNG=O2 (pending: candidates are not rungs); S4 at c1 is not run (exit 0).
Run from the repo root (make test does)."""
import contextlib
import csv
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
import ladder_levers as LL  # noqa: E402
import ladder_select as LS  # noqa: E402
import ladder_tables as lt  # noqa: E402
import ladder_tables_test as T  # noqa: E402

NF = 0
PH = {"setup": 5, "fetch-db": 10, "etag-hash.k2d": 1, "fetch-inputs": 3, "load": 20, "classify": 50, "upload-drain": 2}


def check(what, ok, got=""):
    global NF
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  [got %r]" % (got,)))
    NF += 0 if ok else 1


def sel(root, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = LS.main(["select", "1", "--root", root] + list(args))
    return rc, out.getvalue() + err.getvalue()


def addruns(root, walls, costs=None, bad=None, cohort=1):
    """Runs into ROOT's record: walls {rung: [wall per rep]}, costs {rung: [billed per rep]} (default
    wall/1000), bad: a (rung, rep) whose outputs differ (a Law 1 DEFECT). The arm is the rung's first letter."""
    res = os.path.join(root, "results")
    os.makedirs(os.path.join(res, "g3"), exist_ok=True)
    n = len(os.listdir(os.path.join(res, "g3")))
    for rung, ws in walls.items():
        arm = rung[0]
        for rep, w in enumerate(ws, 1):
            n += 1
            rid = "20261010-%06d-aaaaaaa" % n
            s = T.sample(arm, rung, s5="identical" if arm == "S" else "n/a", outputs=T.BAD if bad == (rung, rep) else None, cohort=cohort)
            T.single(res, rid, arm, rung, rep, w, PH, start=n * 3000, samples=[s], cohort=cohort)
            if costs and rung in costs:
                p = os.path.join(res, "g3", rid, "manifest.json")
                m = json.load(open(p))
                m["cost_usd"] = costs[rung][rep - 1]
                json.dump(m, open(p, "w"))


def mkroot(walls, costs=None, bad=None, cohort=1):
    """A scratch root with the real lever table and the runs of addruns."""
    root = tempfile.mkdtemp(prefix="ak2-select-")
    os.makedirs(os.path.join(root, "scripts", "g3"))
    shutil.copy(os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"), os.path.join(root, "scripts", "g3"))
    addruns(root, walls, costs, bad, cohort)
    return root


def resd(root):
    return os.path.join(root, "scripts", "g3", "ladder.resolved.tsv")


def rows_of(root):
    return {(r["origin"], r["cohort"]): r for r in LL.resolved_rows(resd(root))} if os.path.exists(resd(root)) else {}


def snaps(root):
    d = os.path.join(root, "results", "g3", "ladder-select")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


roots = []
try:
    # 1. Resolved margins; the cost axis picks another winner than the time axis.
    W = {"S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200, 1201]}
    C = {"S9": [1.0, 1.0], "Sstar-r8g": [1.2, 1.2], "Sstar-r8gd": [0.5, 0.5]}
    r1 = mkroot(W, C)
    roots.append(r1)
    rc, out = sel(r1, "--dry-run")
    check("DRY_RUN exits 0 and writes nothing", rc == 0 and not os.path.exists(resd(r1)) and snaps(r1) == [], (rc, out))
    rc, out = sel(r1)
    rs = rows_of(r1)
    t, c = rs.get(("Sstar-time", "1")), rs.get(("Sstar-cost", "1"))
    check("resolved: exit 0, two rows, one snapshot", rc == 0 and t and c and len(snaps(r1)) == 1, (rc, out))
    check("S*-time is S9, margin resolved (100 s > 4 s)", t["value"] == "S9" and t["margin"] == "resolved", t)
    check("S*-cost is Sstar-r8gd (lowest billed, against the time order), margin resolved",
          c["value"] == "Sstar-r8gd" and c["margin"] == "resolved", c)
    check("the note records the rule sha256, each median and the margin",
          hashlib.sha256(LL.by_name(LL.load(os.path.join(r1, "scripts", "g3", "ladder.levers.tsv")))["Sstar-time"]["select"].encode()).hexdigest() in t["note"]
          and "S9 1000.500000 (n 2" in t["note"] and "margin 100.000000" in t["note"], t["note"])
    cites = t["cites"].split()
    check("cites: the snapshot's manifest, rungs.tsv and runs.tsv, and the 6 candidate run manifests",
          len(cites) == 9 and t["source"].startswith("results/g3/ladder-select/c1-") and t["source"].endswith("/manifest.json")
          and sum(x.startswith("results/g3/2026") for x in cites) == 6, cites)
    try:
        ok = LL.read_resolved(resd(r1), r1)[("Sstar-time", "1", "alias")][0] == "S9"
    except ValueError as e:
        ok = str(e)
    check("ladder_levers' citation check passes on the written file", ok is True, ok)
    _, errs = lt.load_resolved(resd(r1), lt.Reader(), lt.load_levers(os.path.join(r1, "scripts", "g3", "ladder.levers.tsv"), lt.Reader()))
    check("the tables read the rows without error", errs == [], errs)
    # The resolver: O0's host is the S*-time winner's.
    v, bad = LL._values(LL.load(os.path.join(r1, "scripts", "g3", "ladder.levers.tsv")), LL.by_name(LL.load(os.path.join(r1, "scripts", "g3", "ladder.levers.tsv")))["O0"], 1,
                        LL.read_resolved(resd(r1), r1))
    check("O0's host resolves to the winner's (x8g.24xlarge)", v.get("instance") == "x8g.24xlarge", (v.get("instance"), bad))
    # 2. Idempotent: byte for byte, no new snapshot.
    before = open(resd(r1)).read()
    rc, out = sel(r1)
    check("a second run: exit 0, file unchanged, no new snapshot",
          rc == 0 and open(resd(r1)).read() == before and len(snaps(r1)) == 1 and "unchanged" in out, (rc, out))
    # 3. A changed record replaces the row, with a new snapshot.
    T.single(os.path.join(r1, "results"), "20261010-000099-aaaaaaa", "S", "S9", 3, 1300, PH, start=99 * 3000,
             samples=[T.sample("S", "S9", s5="identical")])
    rc, out = sel(r1)
    rs = rows_of(r1)
    check("a third S9 run (median 1001 s): the rows are replaced, a second snapshot",
          rc == 0 and len(snaps(r1)) == 2 and "row replaced" in out and rs[("Sstar-time", "1")]["value"] == "S9"
          and "(n 3" in rs[("Sstar-time", "1")]["note"], (rc, out))
    # 4. A cited file changed since: the citation check fails, and ladder-select refuses.
    p = os.path.join(r1, "results", "g3", "20261010-000001-aaaaaaa", "manifest.json")
    with open(p, "a") as f:
        f.write(" ")
    try:
        LL.read_resolved(resd(r1), r1)
        ok = "accepted"
    except ValueError as e:
        ok = "changed since the selection" in str(e) or str(e)
    check("a tampered cited manifest fails ladder_levers' citation check", ok is True, ok)
    before = open(resd(r1)).read()
    rc, out = sel(r1)
    check("ladder-select refuses on a resolved.tsv whose cites fail (exit 3, nothing written)",
          rc == 3 and "citation check" in out and open(resd(r1)).read() == before, (rc, out))

    # 5. Unresolvable: S9 by 2 s against 2 x max(range 1, q 2) = 4 s.
    r2 = mkroot({"S9": [1000, 1001], "Sstar-r8g": [1002, 1003], "Sstar-r8gd": [1200, 1201]})
    roots.append(r2)
    rc, out = sel(r2, "--rung", "Sstar-time")
    t = rows_of(r2).get(("Sstar-time", "1"))
    check("unresolvable: still the rule's winner S9, labelled", rc == 0 and t and t["value"] == "S9" and t["margin"] ==
          "unresolvable: below instrument granularity: chosen by the registered rule from an unresolvable difference", (rc, out, t))
    check("RUNG=Sstar-time writes only that row", set(rows_of(r2)) == {("Sstar-time", "1")}, rows_of(r2))
    rc, out = sel(r2, "--rung", "Sstar-cost")
    check("then RUNG=Sstar-cost adds its row and leaves Sstar-time's", rc == 0 and set(rows_of(r2)) == {("Sstar-time", "1"), ("Sstar-cost", "1")}
          and rows_of(r2)[("Sstar-time", "1")] == t, out)

    # 6. Tie on the median: fewer vCPUs (S9 on x8g.24xlarge, 96) wins over 192.
    r3 = mkroot({"S9": [1000, 1002], "Sstar-r8g": [1001, 1001], "Sstar-r8gd": [1200, 1201]})
    roots.append(r3)
    rc, out = sel(r3, "--rung", "Sstar-time")
    t = rows_of(r3).get(("Sstar-time", "1"))
    check("tie: S9 by fewer vCPUs, margin 0 unresolvable", rc == 0 and t and t["value"] == "S9" and "broken by fewer vCPUs (96 < 192)" in t["note"]
          and t["margin"].startswith("unresolvable"), (rc, out, t))

    # 7. n < 2 on one candidate: not selected (listed) without RUNG; refused with it. Nothing written.
    r4 = mkroot({"S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200]})
    roots.append(r4)
    rc, out = sel(r4)
    check("n = 1 on Sstar-r8gd: listed as not selected (exit 0), nothing written",
          rc == 0 and "not selected: Sstar-time" in out and "Sstar-r8gd has n = 1" in out and not os.path.exists(resd(r4))
          and snaps(r4) == [], (rc, out))
    rc, out = sel(r4, "--rung", "Sstar-time")
    check("RUNG=Sstar-time with n = 1: exit 3, nothing written", rc == 3 and "refused: Sstar-time" in out and not os.path.exists(resd(r4)), (rc, out))

    # 8. A Law 1 DEFECT in the record: refused.
    r5 = mkroot({"S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200, 1201]}, bad=("Sstar-r8g", 2))
    roots.append(r5)
    rc, out = sel(r5)
    check("a Law 1 DEFECT: exit 3, nothing written", rc == 3 and "Law 1" in out and not os.path.exists(resd(r5)), (rc, out))

    # 8b. No summary line from g3-ladder (a crash): refused, nothing written.
    crash = os.path.join(r5, "crash.py")
    with open(crash, "w") as f:
        f.write("import sys\nprint('Traceback (most recent call last): a planted crash', file=sys.stderr)\nsys.exit(1)\n")
    os.environ["AK2_SELECT_TABLES"] = crash
    try:
        rc, out = sel(r2)
    finally:
        del os.environ["AK2_SELECT_TABLES"]
    check("g3-ladder without its summary line: exit 3, Law 1 not judged, nothing changed",
          rc == 3 and "no summary line" in out and "planted crash" in out, (rc, out))

    # 9. Not run at c1, and an alias with no candidate runs.
    rc, out = sel(r2, "--rung", "O2")
    check("RUNG=O2 at c1 without candidate runs: exit 3 (n = 0)", rc == 3 and "O2-r8g has n = 0" in out, (rc, out))
    for rung in ("S4", "O4b"):
        rc, out = sel(r2, "--rung", rung)
        check("RUNG=%s at c1: exit 0, not run there, no row" % rung, rc == 0 and "not-run at c1" in out and (rung, "1") not in rows_of(r2), (rc, out))

    # 10. The parser reads every registered rule; it refuses one without an axis, and duplicate clauses.
    rows = LL.load(os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"))
    parsed = {r["rung"]: LS.parse_rule(r["select"]) for r in rows if r["select"]}
    check("every registered rule parses (axis and ties)",
          parsed["Sstar-time"]["axis"] == "wall_s" and parsed["Sstar-cost"]["axis"] == "billed_usd" and parsed["O3-cost"]["axis"] == "billed_usd"
          and parsed["O3"]["axis"] == "wall_s" and parsed["O4b"]["ties"] == "in flight" and parsed["O2"]["ties"] == "fleet vCPUs"
          and parsed["S4"]["ties"] == "processes" and parsed["S8"]["ties"] == "nodes", parsed)
    for bad, what in (("candidates: S9, Sstar-r8g; ties: fewer vCPUs", "no axis"),
                      ("candidates: S9, Sstar-r8g; axis: median wall_s; axis: median billed_usd; ties: fewer vCPUs", "two axis clauses"),
                      ("candidates: S9, Sstar-r8g; axis: median wall_s; axis: by eye; ties: fewer vCPUs", "an unreadable second axis clause"),
                      ("candidates: S9, Sstar-r8g; axis: median wall_s; ties: fewer vCPUs; ties: fewer nodes", "two ties clauses")):
        try:
            LS.parse_rule(bad)
            ok = False
        except LS.Refused:
            ok = True
        check("a rule with %s is refused" % what, ok)

    # 11. The rule changed since the selection: ladder_levers refuses the row, and so does ladder-select.
    r6 = mkroot(W, C)
    roots.append(r6)
    sel(r6)
    lev6 = os.path.join(r6, "scripts", "g3", "ladder.levers.tsv")
    txt = open(lev6).read()
    old = LL.by_name(LL.load(lev6))["Sstar-time"]["select"]
    with open(lev6, "w") as f:
        f.write(txt.replace(old, old.replace("ties: fewer vCPUs", "ties: fewer vCPUs (edited)"), 1))
    try:
        LL.read_resolved(resd(r6), r6, LL.load(lev6))
        ok = "accepted"
    except ValueError as e:
        ok = "rule changed since the selection" in str(e) or str(e)
    check("a row whose rule text changed is refused by ladder_levers", ok is True, ok)
    rc, out = sel(r6, "--rung", "Sstar-cost")
    check("... and ladder-select refuses on it (exit 3)", rc == 3 and "rule changed" in out, (rc, out))

    # 12. The tables check cites too: a tampered cite leaves the alias unresolved, with a note (r1, case 4).
    o12 = os.path.join(r1, "t12")
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        lt.main(["--results", os.path.join(r1, "results"), "--levers", os.path.join(r1, "scripts", "g3", "ladder.levers.tsv"),
                 "--resolved", resd(r1), "--out", o12])
    rr = [x for x in csv.DictReader(open(os.path.join(o12, "rungs.tsv")), delimiter="\t") if x["rung"] == "Sstar-time" and x["axis"] == "wall_s"]
    man = json.load(open(os.path.join(o12, "manifest.json")))
    check("tables: a row whose cites do not verify is alias unresolved, with a note",
          rr and rr[0]["n"] == "0" and any("cites do not verify" in x for x in man["notes"]), (rr, [x for x in man["notes"] if "cite" in x]))

    # 13. Candidate rungs: S4 at c10 over S2a and the S4-t<T> with P <= 10 (S4-t8 ... S4-t1 left out).
    r7 = mkroot({"S2a": [1000, 1001], "S4-t48": [900, 901], "S4-t32": [800, 801], "S4-t24": [700, 701], "S4-t16": [705, 706],
                 "S4-t12": [750, 751]}, cohort=10)
    roots.append(r7)
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = LS.main(["select", "10", "--root", r7, "--rung", "S4"])
    out = out.getvalue()
    t = {(x["origin"], x["cohort"]): x for x in LL.resolved_rows(resd(r7))}.get(("S4", "10")) if os.path.exists(resd(r7)) else None
    check("S4 at c10: S4-t24 (700.5 s) over S4-t16 (705.5 s), margin 5 s > 4 s resolved; ties by processes",
          rc == 0 and t and t["value"] == "S4-t24" and t["margin"] == "resolved" and "ties fewer processes" in t["note"]
          and "processes 4" in t["note"] and "left out at c10: S4-t8" in t["note"], (rc, out, t))
    r5p = LL.resolve(LL.load(os.path.join(r7, "scripts", "g3", "ladder.levers.tsv")), "S5", 10, resd(r7), r7)["params"]
    check("S5 at c10 takes the winner's THREADS=24, PROCS=vcpus/24 through the alias", (r5p["THREADS"], r5p["PROCS"]) == ("24", "vcpus/24"), r5p)

    # 14. O2 and O2-cost at c1: O1 is not run (O0b's runs), O2-x8g is O1's own type (not run); O2-cost's
    # candidates read the time chain's runs (O0b-cost and O2-cost-r8g are aliases at c1). By time O2-r8g
    # wins; by billed $ the predecessor O1-cost (O0b's runs). O3's candidates have no runs: listed.
    r8 = mkroot({"S0-T1": [5000, 5001], "S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200, 1201], "O0": [900, 901],
                 "O0b": [600, 601], "O2-r8g": [500, 501]},
                costs={"S9": [1.0, 1.0], "Sstar-r8g": [1.2, 1.2], "Sstar-r8gd": [1.5, 1.5], "O0": [0.9, 0.9], "O0b": [1.0, 1.0],
                       "O2-r8g": [2.0, 2.0]})
    roots.append(r8)
    rc, out = sel(r8)
    rs = rows_of(r8)
    o2, o2c = rs.get(("O2", "1")), rs.get(("O2-cost", "1"))
    check("O2 at c1: O2-r8g by time, resolved", rc == 0 and o2 and o2["value"] == "O2-r8g" and o2["margin"] == "resolved"
          and "O1 600.500000" in o2["note"] and "O0b's runs" in o2["note"] and "O2-x8g (not-run at c1" in o2["note"], (rc, out, o2))
    check("O2-cost at c1: O1-cost (O0b's runs) by billed $, and O2-cost-r8g reads O2-r8g's runs",
          o2c and o2c["value"] == "O1-cost" and "O2-r8g's runs" in o2c["note"] and o2c["margin"] == "resolved", o2c)
    check("O3 at c1: listed, its candidates have no runs (bracket widened: no fit in this root)",
          "not selected: O3 at c1" in out and "O3-n2 has n = 0" in out, out)
    lev8 = os.path.join(r8, "scripts", "g3", "ladder.levers.tsv")
    o3 = LL.resolve(LL.load(lev8), "O3-n2", 1, resd(r8), r8)
    check("O3-n2 at c1 is generated on O2's winner's type, N = 2", (o3["instance"], o3["want_n"]) == ("r8g.48xlarge", 2), o3)
    try:
        LL.resolve(LL.load(lev8), "O3-cost-n2", 1, resd(r8), r8)
        ok = "generated"
    except LL.Unresolved as e:
        ok = str(e)
    check("O3-cost-n2 at c1 (O2-cost chose O0b's type) is its own configuration, not O3-n2's", ok == "generated", ok)
    o14 = os.path.join(r8, "t14")
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        lt.main(["--results", os.path.join(r8, "results"), "--levers", lev8, "--resolved", resd(r8), "--out", o14])
    rr = {(x["rung"], x["axis"]): x for x in csv.DictReader(open(os.path.join(o14, "rungs.tsv")), delimiter="\t") if x["cohort"] == "1"}
    check("tables: O2-cost reads O0b's runs (via O1-cost, O0b-cost) and O0-cost reads O0's",
          rr[("O2-cost", "wall_s")]["median"] == rr[("O0b", "wall_s")]["median"] and rr[("O0-cost", "wall_s")]["median"] == rr[("O0", "wall_s")]["median"]
          and "same configuration as O0b at c1" in rr[("O2-cost", "wall_s")]["basis"], (rr.get(("O2-cost", "wall_s")), rr.get(("O0-cost", "wall_s"))))
finally:
    for r in roots:
        shutil.rmtree(r, ignore_errors=True)
print("ladder_select_test: %d failure(s)" % NF)
sys.exit(1 if NF else 0)
