#!/usr/bin/env python3
"""make ladder-advance's test (scripts/lib/ladder_advance.py; docs/ladder.md, "Advancing a cohort"):
on the real lever table and the committed c1 record, with only the c1 resolutions (so the test does
not move as c10 selections are committed) and hypothetical c10 selections where a case needs them.
No AWS call: prices come from scripts/g3/ladder.types.tsv and the AK2_ADVANCE_PRICES seam."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
os.environ.setdefault("AK2_ADVANCE_PRICES", "r8gd.48xlarge=14.10816")
import ladder_advance as A  # noqa: E402
import ladder_levers as LL  # noqa: E402
import ladder_ttl as TT  # noqa: E402

NF = 0


def check(what, ok, got=""):
    global NF
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  [got %r]" % (got,)))
    NF += 0 if ok else 1


rows = LL.load()
names = LL.by_name(rows)
A.ORDER[:] = [r["rung"] for r in rows]
res = LL.read_resolved(LL.RESOLVED, ROOT, rows)
res1 = {k: v for k, v in res.items() if k[1] == "1"}
STAGE1 = ["S0-T1", "S0-Tv", "S1", "S2b-i", "S2b-ii", "S2d", "S2c", "S2a", "S4-t48", "S4-t32", "S4-t24", "S4-t16", "S4-t12"]

# 1. The refusal classes.
for msg, want in (("S4-t8 is not-run at c10: P = 96/8 = 12 processes > cohort 10: no spec is generated for it", ("not-run", [])),
                  ("O0-cost is alias: same configuration as O0 at c10 (alias_cohorts): no spec is generated for it; O0's runs are read", ("alias", [])),
                  ("O3-n16 at cohort 10 is outside O3's bracket (...): not a candidate there", ("out", [])),
                  ("O3-n2 at cohort 10 is outside O3's candidates (its REPLICAS+SHARDS is O2's own: ...): not a candidate there", ("out", [])),
                  ("O1 is not-run at c100: where S8 keeps K = 1 ... (conditional: it resolves to O0b's configuration): no spec is generated for it",
                   ("not-run", [])),
                  ("O1 at cohort 10: the resolution makes it identical to O0b (mark it not-run instead)", ("collapsed", [])),
                  ("S5 at cohort 10 has unresolved values: THREADS=@select:S4, PROCS=@select:S4", ("pending", ["S4"])),
                  ("O3-n2 at cohort 10 has unresolved values: instance=@floor:O2 (its origin's host is unresolved)", ("pending", ["O2"])),
                  ("O3-n2 at cohort 10: resolved, it changes instance against O1, not just the group REPLICAS+SHARDS", ("blocked", []))):
    check("classify: %s -> %s" % (msg[:60], want[0]), A.classify(msg) == want, A.classify(msg))

# 2. The stages at c10 (static, from the table).
st = A.stages(rows, 10)
want = dict([(r, 1) for r in STAGE1] + [(r, 2) for r in ("S5", "S6", "S7a", "S7b", "S8-k2")] +
            [(r, 3) for r in ("S9", "Sstar-r8g", "Sstar-r8gd")] + [(r, 4) for r in ("O0", "O0b", "O1", "O0-cost", "O0b-cost", "O1-cost")] +
            [(r, 5) for r in ("O3-n2", "O3-n32", "O3-cost-n2")] + [(r, 6) for r in ("O4a", "O4b-if1", "O4a-cost", "O4b-cost-if2")] +
            [(r, 7) for r in ("O5", "O5-cost")] + [(r, 1) for r in ("S4",)] + [(r, 2) for r in ("S8",)] +
            [(r, 3) for r in ("Sstar-time", "Sstar-cost")] + [("O2", 4), ("O3", 5), ("O4b", 6)])
check("stages at c10: 1 (S0-T1 ... S4-t12), 2 (S5 ... S8-k2), 3 (S9, S*), 4 (O0, O0b, O1), 5 (O3-n<K>), 6 (O4a, O4b-if<k>), 7 (O5)",
      all(st[k] == v for k, v in want.items()), {k: (st[k], v) for k, v in want.items() if st[k] != v})

# 3. The plan at c10 on the c1 resolutions alone: stage 1 is determined, the rest waits.
prices = A.Prices(ROOT)
rec = TT.c1_record(ROOT)
entries, sels = A.plan(rows, 10, res1, ROOT, prices, rec, res1, with_bounds=False)
by = {e["rung"]: e for e in entries}
det = [e["rung"] for e in entries if e["state"] in ("new", "committed")]
check("c10: the determined rungs are exactly stage 1 (S0-T1 ... S2a and S4-t48 ... S4-t12)", det == STAGE1, det)
check("c10: S4-t8 ... S4-t1 are not run (P > 10), and so are O4b-if16 and up",
      all(by[r]["state"] == "not-run" for r in ("S4-t8", "S4-t1", "O4b-if16", "O4b-cost-if128")),
      {r: by[r]["state"] for r in ("S4-t8", "S4-t1", "O4b-if16")})
check("c10: O2-r8g and O2-x8g are run there, pending (their types follow O1's N = S8's K: @fit:<family>)",
      all(by[r]["state"] == "pending" for r in ("O2-r8g", "O2-x8g", "O2-cost-r8g", "O2-cost-x8g")),
      {r: by[r]["state"] for r in ("O2-r8g", "O2-x8g", "O2-cost-r8g", "O2-cost-x8g")})
check("c10: S5 waits on S4; S9 on S4 and S8; O0 on S*-time too", by["S5"]["state"] == "pending" and by["S5"]["waits"] == ["S4"]
      and set(by["S9"]["waits"]) == {"S4", "S8"} and "Sstar-time" in by["O0"]["waits"], (by["S5"]["waits"], by["S9"]["waits"], by["O0"]["waits"]))
e0 = by["S0-T1"]
check("c10: S0-T1's TTL is estimated from its own c1 runs and is within AK2_MAX_TTL_S", e0["basis"].startswith("its own c1 runs")
      and 30 <= int(e0["ttl_min"]) <= TT.max_ttl_s() // 60 and abs(float(e0["total"]) - A.cost_limit(14.10816, int(e0["ttl_min"]))) < 1e-9, e0)
check("c10: S4-t12's basis is S2a's c1 runs", "the c1 runs of S2a" in by["S4-t12"]["basis"], by["S4-t12"]["basis"])
sb = {s["rung"]: s for s in sels}
check("c10: S4 waits on the campaign; S8 waits on S4", sb["S4"]["state"] == "pending" and "waits on the campaign" in sb["S4"]["why"]
      and "waits on selection(s) S4" in sb["S8"]["why"], (sb["S4"], sb["S8"]))
check("c10: O2 and O2-cost are no longer BLOCKED: three candidates each (O1, O2-r8g, O2-x8g at O1's N)",
      sb["O2"]["state"] == "pending" and "O2-r8g (pending)" in sb["O2"]["why"] and "O2-x8g (pending)" in sb["O2"]["why"]
      and sb["O2-cost"]["state"] == "pending", (sb["O2"], sb["O2-cost"]))
check("c10: O4b's in-flight range is noted", "in-flight range" in sb["O4b"]["why"], sb["O4b"])

# 4. A hypothetical S4 selection (S4 -> S4-t24) determines stage 2, with S4-t24's THREADS and PROCS.
h = dict(res1)
h[("S4", "10", "alias")] = ("S4-t24", "hypothetical")
entries, sels = A.plan(rows, 10, h, ROOT, prices, rec, res1, with_bounds=False)
by = {e["rung"]: e for e in entries}
det = [e["rung"] for e in entries if e["state"] in ("new", "committed")]
check("S4 -> S4-t24: stage 2 (S5, S6, S7a, S7b, S8-k2) is determined as well",
      all(r in det for r in ("S5", "S6", "S7a", "S7b", "S8-k2")) and by["S9"]["state"] == "pending", det)
check("... S5 runs THREADS=24, PROCS=vcpus/24; S8-k2 on 2 nodes", "THREADS=24; PROCS=vcpus/24" in by["S5"]["line"] and by["S8-k2"]["nodes"] == 2,
      (by["S5"]["line"], by["S8-k2"]["nodes"]))
check("... and the rehearsal classes split S5 (several lanes, 1 node) from S8-k2 (2 nodes)",
      A.fleet_class(by["S5"])[0] != A.fleet_class(by["S8-k2"])[0] and A.fleet_class(by["S5"])[1] == 4, (A.fleet_class(by["S5"]), A.fleet_class(by["S8-k2"])))

# 5. Bounds: S5 over the six S4 winners; O1 collapses where S8 keeps K = 1.
b, n, okn, why = A.bound(rows, "S5", 10, res1, prices, rec, res1, ROOT)
check("bound: S5 at c10 over the 6 S4 candidates, every one resolved", n == 6 and okn == 6 and b and b > 0, (b, n, okn, why))
b, n, okn, why = A.bound(rows, "O1", 10, res1, prices, rec, res1, ROOT)
check("bound: O1 at c10 is a conditional not-run wherever S8 -> S7b (K = 1): not generated under half the combinations",
      n == 36 and okn == 18 and any("conditional: it resolves to O0b's configuration" in k and "not-run" in k for k in why), (n, okn, dict(why)))
ow = A.own_rows(rows, 10)
check("own_rows drops the c10 conditional entries and keeps c1's",
      LL.by_name(ow)["O0-cost"]["alias_cohorts"] == "c1: O0" and LL.by_name(ow)["O5-cost"]["alias_cohorts"] == "c1: O5 (if same configuration)",
      (LL.by_name(ow)["O0-cost"]["alias_cohorts"], LL.by_name(ow)["O5-cost"]["alias_cohorts"]))

# 6. DRY_RUN end to end (no select: no fresh selection of the real record) writes nothing in the repo.
before = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"], capture_output=True, text=True).stdout
p = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "lib", "ladder_advance.py"), "advance", "10", "--dry-run", "--no-select"],
                   capture_output=True, text=True)
after = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"], capture_output=True, text=True).stdout
check("DRY_RUN at c10: exit 0, the stage plan and the rehearsal classes printed, nothing written",
      p.returncode == 0 and "stage plan at c10" in p.stdout and ("rehearsal classes" in p.stdout or "no new spec at c10" in p.stdout) and before == after,
      (p.returncode, p.stdout[-800:], p.stderr[-800:]))
print("ladder_advance_test: %d failure(s)" % NF)
sys.exit(1 if NF else 0)
