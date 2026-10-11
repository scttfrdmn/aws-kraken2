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


def mkroot(walls, costs=None, bad=None):
    """A scratch root: walls {rung: [wall per rep]}, costs {rung: [billed per rep]} (default wall/1000),
    bad: a (rung, rep) whose outputs differ (a Law 1 DEFECT)."""
    root = tempfile.mkdtemp(prefix="ak2-select-")
    os.makedirs(os.path.join(root, "scripts", "g3"))
    shutil.copy(os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"), os.path.join(root, "scripts", "g3"))
    res = os.path.join(root, "results")
    os.makedirs(os.path.join(res, "g3"))
    n = 0
    for rung, ws in walls.items():
        for rep, w in enumerate(ws, 1):
            n += 1
            rid = "20261010-%06d-aaaaaaa" % n
            s = T.sample("S", rung, s5="identical", outputs=T.BAD if bad == (rung, rep) else None)
            T.single(res, rid, "S", rung, rep, w, PH, start=n * 3000, samples=[s])
            if costs:
                p = os.path.join(res, "g3", rid, "manifest.json")
                m = json.load(open(p))
                m["cost_usd"] = costs[rung][rep - 1]
                json.dump(m, open(p, "w"))
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

    # 7. n < 2 on one candidate: refused, nothing written.
    r4 = mkroot({"S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200]})
    roots.append(r4)
    rc, out = sel(r4)
    check("n = 1 on Sstar-r8gd: exit 3, nothing written", rc == 3 and "Sstar-r8gd has n = 1" in out and not os.path.exists(resd(r4))
          and snaps(r4) == [], (rc, out))

    # 8. A Law 1 DEFECT in the record: refused.
    r5 = mkroot({"S9": [1000, 1001], "Sstar-r8g": [1100, 1101], "Sstar-r8gd": [1200, 1201]}, bad=("Sstar-r8g", 2))
    roots.append(r5)
    rc, out = sel(r5)
    check("a Law 1 DEFECT: exit 3, nothing written", rc == 3 and "Law 1" in out and not os.path.exists(resd(r5)), (rc, out))

    # 9. Rules that are not selected from ladder medians.
    rc, out = sel(r2, "--rung", "O2")
    check("RUNG=O2: exit 3 (its candidates are not rungs)", rc == 3 and "O2 at c1: pending" in out, (rc, out))
    rc, out = sel(r2, "--rung", "S4")
    check("RUNG=S4 at c1: exit 0, not run there, no row", rc == 0 and "not-run at c1" in out and ("S4", "1") not in rows_of(r2), (rc, out))
    rc, out = sel(r2, "--rung", "O4b")
    check("RUNG=O4b at c1: its one candidate is O4a's INFLIGHT = 1 (exit 3)", rc == 3 and "only candidate at c1 is INFLIGHT = 1" in out, (rc, out))
    # 10. The parser reads every registered rule, and refuses one without an axis.
    rows = LL.load(os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"))
    parsed = {r["rung"]: LS.parse_rule(r["select"]) for r in rows if r["select"]}
    check("every registered rule parses (axis and ties)",
          parsed["Sstar-time"]["axis"] == "wall_s" and parsed["Sstar-cost"]["axis"] == "billed_usd" and parsed["O3-cost"]["axis"] == "fit:cost"
          and parsed["O4b"]["ties"] == "in flight" and parsed["O2"]["ties"] == "fleet vCPUs" and parsed["S4"]["ties"] == "processes", parsed)
    try:
        LS.parse_rule("candidates: S9, Sstar-r8g; ties: fewer vCPUs")
        ok = False
    except LS.Refused:
        ok = True
    check("a rule without an axis is refused", ok)
finally:
    for r in roots:
        shutil.rmtree(r, ignore_errors=True)
print("ladder_select_test: %d failure(s)" % NF)
sys.exit(1 if NF else 0)
