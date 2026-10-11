#!/usr/bin/env python3
"""make ladder-campaign-test (in make test): scripts/lib/ladder_campaign.py against stubs, no AWS.

Each scenario runs the real planner and driver in a scratch git repo holding the real committed
c1 specs of a few rungs, the real lever table, ladder_levers.py and quota_check.sh, a synthetic
record, and a scratch AZ list. `make run`, `make orphans`, `make g3-ladder` and quota_check.sh are
stubs (the driver's AK2_CAMPAIGN_* seams); the run stub writes a cohort dir as run-multi.sh does,
with params from the real `ladder_levers.py spec-params --rep $AK2_LADDER_REP`, and logs each
start and end. Scenarios:
  plan       ordering (cost, then ladder order), rep 2 reversed, skipping done runs, and the runs
             not counted (failed, a recorded defect, params that differ);
  skip       the run skips the done (rung, rep) and launches the rest;
  normal     the first launch runs alone, the X family never exceeds its limit (and reaches it),
             rep 2 of a rung starts after its rep 1 ends, AK2_LADDER_REP reaches params.rep, no
             launch while quota_check refuses, make orphans after every run;
  capacity   x8g: one retry in the documented AZ (AK2_LAUNCH_AZ), then rep 2 in the spec's AZ;
             r8gd: no documented alternative, so the rung stops; both capacity rows reach
             g3_defects.tsv at the end;
  failure    a failed run stops its rung (rep 2 not launched); the other rung carries on;
  orphans    a finding with a run in flight is informational; with nothing in flight it stops
             the campaign (exit 3) before the next launch;
  law1       a Law 1 DEFECT from g3-ladder stops the campaign; one already in the record refuses
             to start.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.dont_write_bytecode = True
PASS, FAIL = [0], [0]


def ok(cond, msg, detail=""):
    if cond:
        PASS[0] += 1
        print("ladder_campaign_test: ok   %s" % msg)
    else:
        FAIL[0] += 1
        print("ladder_campaign_test: FAIL %s %s" % (msg, detail))


STUB_RUN = r'''#!/usr/bin/env python3
import json, os, random, subprocess, sys, time
S = os.environ["AK2T"]
a = dict(x.split("=", 1) for x in sys.argv[1:])
spec = json.load(open(a["SPEC"]))
p = json.loads(subprocess.run(["python3", "scripts/lib/ladder_levers.py", "spec-params", a["SPEC"], "--rep",
                               os.environ.get("AK2_LADDER_REP", "1")], capture_output=True, text=True).stdout)
rung, rep = p["rung"], int(os.environ.get("AK2_LADDER_REP", "0"))
az = os.environ.get("AK2_LAUNCH_AZ") or spec["placement"]["availability_zone"]
beh = json.load(open(os.path.join(S, "behave.json")))
b = dict({"s": 0.4, "r": "ok", "cost": 1.0}, **beh.get("%s:%d" % (rung, rep), {}))
b = dict(b, **beh.get("%s:%d:%s" % (rung, rep, az), {})) if os.environ.get("AK2_LAUNCH_AZ") else b
def ev(kind):
    with open(os.path.join(S, "events.jsonl"), "a") as f:
        f.write(json.dumps({"ev": kind, "rung": rung, "rep": rep, "az": az, "type": spec["resources"]["instance_type"],
                            "t": time.time(), "env_rep": os.environ.get("AK2_LADDER_REP"),
                            "env_az": os.environ.get("AK2_LAUNCH_AZ"), "dry": os.environ.get("DRY_RUN") or os.environ.get("MAKEFLAGS")}) + "\n")
if b["r"] == "quota":
    ev("refused")
    print("quota_check: REFUSED: ...\nmake run (multi): refused before launch: 1 x t would exceed the region's on-demand vCPU quota (above)")
    sys.exit(2)
n = int(a["NODES"])
cid = "20261012-%s-abcdef0-%04x-n%d" % (time.strftime("%H%M%S"), random.randrange(65536), n)
print("make run (multi): cohort %s: %d x %s in %s -> s3://b/%s" % (cid, n, spec["resources"]["instance_type"], az, cid), flush=True)
os.makedirs("results/g3/%s" % cid)
ev("start")
for k in range(n):
    os.makedirs("results/g3/%s-r%d" % (cid, k))
    json.dump({"cohort": {"id": cid}, "params": p, "launch": {"instance_id": None if b["r"] == "capacity" else "i-%d" % k}},
              open("results/g3/%s-r%d/manifest.json" % (cid, k), "w"))
time.sleep(b["s"])
if b.get("law1"):
    open(os.path.join(S, "law1"), "w").close()
ex = {"ok": 0, "fail": 1, "capacity": None}[b["r"]]
if b["r"] == "capacity":
    open("results/g3/%s/rank-0.run.log" % cid, "w").write("An error occurred (InsufficientInstanceCapacity) ...\n")
mem = [{"rank": k, "run_id": "%s-r%d" % (cid, k), "exit_code": ex, "cost_usd": None if ex is None else b["cost"],
        "instance_id": None if ex is None else "i-%d" % k} for k in range(n)]
json.dump({"cohort_id": cid, "params": p, "nodes": n, "az": az, "members": mem,
           "ended": "members done" if ex == 0 else "members done (fail fast: rank 0 exited 1)",
           "cost_usd": None if ex is None else b["cost"] * n}, open("results/g3/%s/cohort.json" % cid, "w"))
ev("end")
sys.exit(0 if ex == 0 else 1)
'''

STUB_ORPHANS = r'''#!/usr/bin/env python3
import json, os, time
S = os.environ["AK2T"]
seq = [int(x) for x in open(os.path.join(S, "orphans_seq")).read().split()] if os.path.exists(os.path.join(S, "orphans_seq")) else []
log = os.path.join(S, "orphans.log")
n = sum(1 for _ in open(log)) if os.path.exists(log) else 0
rc = seq[n] if n < len(seq) else 0
open(log, "a").write("%f %d\n" % (time.time(), rc))
print("orphans stub: rc %d" % rc)
raise SystemExit(rc)
'''

STUB_G3 = r'''#!/usr/bin/env python3
import os, sys
S = os.environ["AK2T"]
if os.path.exists(os.path.join(S, "law1")):
    print("ladder_tables: DEFECT (Law 1): SRR1: output sha256 differs", file=sys.stderr)
    raise SystemExit(1)
print("ladder_tables: DEFECT (contract): an older run (not Law 1)", file=sys.stderr)
raise SystemExit(1)
'''

STUB_QUOTA = r'''#!/usr/bin/env python3
import os, sys, time
S = os.environ["AK2T"]
log = os.path.join(S, "quota.log")
n = sum(1 for _ in open(log)) if os.path.exists(log) else 0
refuse = int(open(os.path.join(S, "quota_refuse")).read()) if os.path.exists(os.path.join(S, "quota_refuse")) else 0
rc = 1 if n < refuse else 0
open(log, "a").write("%f %d %s\n" % (time.time(), rc, " ".join(sys.argv[1:])))
print("quota_check: %s: stub" % ("REFUSED" if rc else "ok"), file=sys.stderr)
raise SystemExit(rc)
'''


def scratch(rungs, record=(), defects=(), azs=None):
    d = tempfile.mkdtemp(prefix="ladder-campaign-test.")
    R = os.path.join(d, "repo")
    for sub in ("scripts/lib", "scripts/g3", "runs", "results/g3", "stub"):
        os.makedirs(os.path.join(R, sub), exist_ok=True)
    for f in ("scripts/lib/ladder_campaign.py", "scripts/lib/ladder_levers.py", "scripts/lib/quota_check.sh",
              "scripts/g3/ladder.levers.tsv", "scripts/g3/ladder-campaign.sh"):
        shutil.copy2(os.path.join(HERE, f), os.path.join(R, f))
    for r in rungs:
        shutil.copy2(os.path.join(HERE, "runs", "g3-l-%s-c1.json" % r.lower()), os.path.join(R, "runs"))
    with open(os.path.join(R, "scripts/lib/g3_defects.tsv"), "w") as f:
        f.write("run\tclass\tevidence\n")
        for row in defects:
            f.write("\t".join(row) + "\n")
    # Evidence manifests for the scratch AZ list.
    for t, z in (("x8g.24xlarge", "us-west-2c"), ("x8g.24xlarge", "us-west-2b"), ("r8gd.48xlarge", "us-west-2b")):
        e = os.path.join(R, "results", "ev", "%s-%s" % (t, z))
        os.makedirs(e)
        json.dump({"instance": {"type": t, "az": z}}, open(os.path.join(e, "manifest.json"), "w"))
    with open(os.path.join(R, "scripts/g3/ladder.azs.tsv"), "w") as f:
        f.write("type\taz\tevidence\n")
        for t, z in azs or (("x8g.24xlarge", "us-west-2c"), ("x8g.24xlarge", "us-west-2b"), ("r8gd.48xlarge", "us-west-2b")):
            f.write("%s\t%s\tresults/ev/%s-%s/manifest.json\n" % (t, z, t, z))
    for rd, cj in record:
        os.makedirs(os.path.join(R, "results", "g3", rd))
        json.dump(cj, open(os.path.join(R, "results", "g3", rd, "cohort.json"), "w"))
    for name, body in (("run", STUB_RUN), ("orphans", STUB_ORPHANS), ("g3ladder", STUB_G3), ("quota", STUB_QUOTA)):
        p = os.path.join(R, "stub", name)
        open(p, "w").write(body)
        os.chmod(p, 0o755)
    S = os.path.join(d, "state")
    os.makedirs(S)
    json.dump({}, open(os.path.join(S, "behave.json"), "w"))
    subprocess.run("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t", shell=True, cwd=R, check=True)
    return d, R, S


def params_of(R, rung, **over):
    spec = json.load(open(os.path.join(R, "runs", "g3-l-%s-c1.json" % rung.lower())))
    sys.path.insert(0, os.path.join(R, "scripts", "lib"))
    import ladder_levers
    p = ladder_levers.spec_params(spec)
    p.update(over)
    return p


def done_cohort(params, ok=True, cost=1.24):
    return {"params": params, "nodes": 1, "ended": "members done" if ok else "members done (fail fast: rank 0 exited 1)",
            "members": [{"rank": 0, "run_id": "x-r0", "exit_code": 0 if ok else 1, "cost_usd": cost}], "cost_usd": cost}


def campaign(R, S, mode, rungs, reps=2, limits="X=2,Standard=2", behave=None, files=None):
    if behave:
        json.dump(behave, open(os.path.join(S, "behave.json"), "w"))
    for k, v in (files or {}).items():
        open(os.path.join(S, k), "w").write(v)
    env = dict(os.environ, AK2T=S, AK2_CAMPAIGN_RUN=os.path.join(R, "stub", "run"),
               AK2_CAMPAIGN_ORPHANS=os.path.join(R, "stub", "orphans"), AK2_CAMPAIGN_G3LADDER=os.path.join(R, "stub", "g3ladder"),
               AK2_CAMPAIGN_QUOTA=os.path.join(R, "stub", "quota"), AK2_CAMPAIGN_POLL_S="0.05", AK2_CAMPAIGN_QUOTA_RETRY_S="0", DRY_RUN="",
               MAKEFLAGS="DRY_RUN=1")
    r = subprocess.run(["python3", "scripts/lib/ladder_campaign.py", mode, "1", "--reps", str(reps), "--rungs", ",".join(rungs),
                        "--family-limits", limits], cwd=R, env=env, capture_output=True, text=True, timeout=300)
    evs = [json.loads(l) for l in open(os.path.join(S, "events.jsonl"))] if os.path.exists(os.path.join(S, "events.jsonl")) else []
    return r.returncode, r.stdout + r.stderr, evs


def plan_rows(out):
    rows = []
    for l in out.splitlines():
        c = l.split()
        if len(c) > 3 and c[0].isdigit() and c[1].isdigit():
            rows.append((int(c[1]), c[2], "skip" if " skip: " in l else "launch"))
    return rows


def campaign_tsv(R):
    d = os.path.join(R, "results", "g3", "ladder-campaign")
    fs = sorted(f for f in os.listdir(d) if f.endswith(".tsv") and not f.endswith(".defects.tsv"))
    return [l.rstrip("\n").split("\t") for l in open(os.path.join(d, fs[-1]))][1:]


def concurrency(evs, pred):
    cur, peak = 0, 0
    for e in sorted((e for e in evs if e["ev"] in ("start", "end") and pred(e)), key=lambda e: (e["t"], e["ev"] == "start")):
        cur += 1 if e["ev"] == "start" else -1
        peak = max(peak, cur)
    return peak


def t_of(evs, kind, rung, rep, az=None):
    for e in evs:
        if e["ev"] == kind and e["rung"] == rung and e["rep"] == rep and (az is None or e["az"] == az):
            return e["t"]
    return None


def main():
    rungs = ["S0-T1", "S1", "S2a", "S5", "S6"]
    # ---- plan
    d, R, S = scratch(rungs)
    rec = [("20261011-000001-aaaaaaa-0001-n1", done_cohort(params_of(R, "S2a"))),                  # done, no params.rep
           ("20261011-000002-aaaaaaa-0002-n1", done_cohort(params_of(R, "S5"), ok=False)),         # failed
           ("20261011-000003-aaaaaaa-0003-n1", done_cohort(params_of(R, "S6"))),                   # a recorded defect
           ("20261011-000004-aaaaaaa-0004-n1", done_cohort(params_of(R, "S1", threads="96"))),     # params differ
           ("20261011-000005-aaaaaaa-0005-n1", done_cohort(params_of(R, "S0-T1", rep=2), cost=50.0))]   # rep 2 done
    shutil.rmtree(d)
    d, R, S = scratch(rungs, record=rec, defects=[("20261011-000003-aaaaaaa-0003-n1", "defect: x", "y")])
    rc, out, _ = campaign(R, S, "plan", rungs)
    rows = plan_rows(out)
    want = [(1, "S2a", "skip"), (1, "S5", "launch"), (1, "S6", "launch"), (1, "S1", "launch"), (1, "S0-T1", "launch"),
            (2, "S0-T1", "skip"), (2, "S1", "launch"), (2, "S6", "launch"), (2, "S5", "launch"), (2, "S2a", "launch")]
    # S0-T1's measured $50 (its rep-2 run) still sorts it last; S2a's measured $1.24 first; S5 and S6
    # tie at cost_limit and go in ladder order.
    ok(rc == 0 and rows == want, "plan: rep 1 cheapest first (measured, then estimate; ties in ladder order), rep 2 reversed, done skipped",
       "rc %d rows %s\n%s" % (rc, rows, out))
    ok("rep 1 by default (no params.rep)" in out and "000002-aaaaaaa-0002-n1" in out and "member exit r0=1" in out
       and "recorded defect (g3_defects.tsv 20261011-000003" in out and "params differ from runs/g3-l-s1-c1.json: threads '96' != 'vcpus'" in out,
       "plan: lists why each record run is or is not counted", out)
    ok(not os.path.exists(os.path.join(R, "results", "g3", "ladder-campaign")) and not os.path.exists(os.path.join(S, "events.jsonl")),
       "plan: DRY_RUN writes nothing and launches nothing")
    shutil.rmtree(d)

    # ---- skip (run mode): S2a rep 1 is done
    d, R, S = scratch(["S2a", "S5"])
    rec = [("20261011-000001-aaaaaaa-0001-n1", done_cohort(params_of(R, "S2a")))]
    shutil.rmtree(d)
    d, R, S = scratch(["S2a", "S5"], record=rec)
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5"], behave={})
    starts = [(e["rung"], e["rep"]) for e in evs if e["ev"] == "start"]
    ok(rc == 0 and sorted(starts) == [("S2a", 2), ("S5", 1), ("S5", 2)], "skip: the done S2a rep 1 is not launched; the rest are",
       "rc %d starts %s\n%s" % (rc, starts, out[-2000:]))
    tsv = campaign_tsv(R)
    ok(any(r[1] == "S2a" and r[2] == "1" and r[7] == "skip" and r[4] == "results/g3/20261011-000001-aaaaaaa-0001-n1" for r in tsv),
       "skip: the campaign log records the skip and the run that did it", tsv)
    shutil.rmtree(d)

    # ---- normal
    rs = ["S1", "S2a", "S5", "S6", "S0-T1"]
    d, R, S = scratch(rs)
    beh = {"S2a:1": {"s": 0.6}, "S5:1": {"s": 1.2}, "S6:1": {"s": 1.2}, "S1:1": {"s": 0.8}, "S0-T1:1": {"s": 0.8}}
    rc, out, evs = campaign(R, S, "run", rs, behave=beh, files={"quota_refuse": "2"})
    starts = [e for e in evs if e["ev"] == "start"]
    ok(rc == 0 and len(starts) == 10, "normal: exit 0, 10 launches", "rc %d %d starts\n%s" % (rc, len(starts), out[-3000:]))
    first = sorted(starts, key=lambda e: e["t"])[0]
    ok((first["rung"], first["rep"]) == ("S2a", 1) and all(e["t"] >= t_of(evs, "end", "S2a", 1) for e in starts if e is not first),
       "normal: the cheapest (S2a rep 1) runs first and alone", [(e["rung"], e["rep"]) for e in sorted(starts, key=lambda e: e["t"])])
    px = concurrency(evs, lambda e: e["type"].startswith("x8g"))
    ok(px == 2, "normal: the X family reaches its limit of 2 and never exceeds it (peak %d)" % px)
    ok(concurrency(evs, lambda e: True) <= 4, "normal: never more than the two families' limits in flight")
    ok(all(t_of(evs, "start", r, 2) >= t_of(evs, "end", r, 1) for r in rs), "normal: every rung's rep 2 starts after its rep 1 ends")
    ok(all(e["env_rep"] == str(e["rep"]) and not e["dry"] for e in starts), "normal: AK2_LADDER_REP is each launch's rep (DRY_RUN and the parent make's MAKEFLAGS not passed on)")
    cjs = [json.load(open(os.path.join(R, "results", "g3", c, "cohort.json"))) for c in os.listdir(os.path.join(R, "results", "g3"))
           if os.path.exists(os.path.join(R, "results", "g3", c, "cohort.json"))]
    ok(sorted((c["params"]["rung"], c["params"]["rep"]) for c in cjs) == sorted((e["rung"], e["rep"]) for e in starts)
       and all(c["params"]["rep_source"].startswith("AK2_LADDER_REP") for c in cjs), "normal: params.rep (with rep_source) reaches every cohort.json")
    q = [l.split() for l in open(os.path.join(S, "quota.log"))]
    ok([x[1] for x in q[:3]] == ["1", "1", "0"] and float(first["t"]) >= float(q[2][0]),
       "normal: no launch while quota_check refuses (2 refusals, then the first launch)")
    no = sum(1 for _ in open(os.path.join(S, "orphans.log")))
    ok(no == 10 + 2, "normal: make orphans before, after each of the 10 runs, and at the end (%d calls)" % no)
    tsv = campaign_tsv(R)
    ok(len(tsv) == 10 and all(r[7] == "ok" and r[4].startswith("results/g3/2026") and r[5] == "0" and r[6] == "1.0" for r in tsv),
       "normal: the campaign log has rung, rep, run dir, exit, cost and class per run", tsv)
    shutil.rmtree(d)

    # ---- capacity
    d, R, S = scratch(["S1", "S5"])
    beh = {"S5:1": {"r": "capacity"}, "S5:1:us-west-2c": {"r": "ok"}, "S1:1": {"r": "capacity"}}
    rc, out, evs = campaign(R, S, "run", ["S1", "S5"], behave=beh)
    starts = [(e["rung"], e["rep"], e["az"], e["env_az"]) for e in evs if e["ev"] == "start"]
    ok(("S5", 1, "us-west-2b", None) in starts and ("S5", 1, "us-west-2c", "us-west-2c") in starts and ("S5", 2, "us-west-2b", None) in starts,
       "capacity: x8g retried once in the documented us-west-2c (AK2_LAUNCH_AZ), rep 2 back in the spec's AZ", starts)
    ok(("S1", 1, "us-west-2b", None) in starts and not any(s[0] == "S1" and s[1] == 2 for s in starts) and len(starts) == 4,
       "capacity: r8gd has no documented alternative AZ, so S1 stops (rep 2 not launched)", starts)
    dl = [l.rstrip("\n").split("\t") for l in open(os.path.join(R, "scripts/lib/g3_defects.tsv"))][1:]
    ok(rc == 1 and len(dl) == 2 and all(r[1].startswith("capacity: InsufficientInstanceCapacity in us-west-2b") for r in dl),
       "capacity: exit 1; both capacity rows appended to g3_defects.tsv at the end", "rc %d %s" % (rc, dl))
    tsv = campaign_tsv(R)
    ok([r[7] for r in tsv if r[1] == "S1"] == ["capacity", "not-launched"], "capacity: S1's log rows: capacity, then rep 2 not launched", tsv)
    shutil.rmtree(d)

    # ---- failure
    d, R, S = scratch(["S5", "S6"])
    rc, out, evs = campaign(R, S, "run", ["S5", "S6"], behave={"S5:1": {"r": "fail"}})
    starts = sorted((e["rung"], e["rep"]) for e in evs if e["ev"] == "start")
    ok(rc == 1 and starts == [("S5", 1), ("S6", 1), ("S6", 2)], "failure: S5 fails, its rep 2 is not launched; S6 carries on",
       "rc %d %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)

    # ---- orphans: informational with a run in flight; a hard stop with none
    d, R, S = scratch(["S2a", "S5", "S6"])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5", "S6"], reps=1,
                            behave={"S2a:1": {"s": 0.3}, "S5:1": {"s": 2.0}, "S6:1": {"s": 0.3}}, files={"orphans_seq": "0 0 1 0 0"})
    ok(rc == 0 and len([e for e in evs if e["ev"] == "start"]) == 3 and "informational" in out,
       "orphans: a finding while S5 is in flight is informational; the campaign goes on", "rc %d\n%s" % (rc, out[-2000:]))
    shutil.rmtree(d)
    d, R, S = scratch(["S2a", "S5"])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5"], files={"orphans_seq": "0 1"})
    starts = [(e["rung"], e["rep"]) for e in evs if e["ev"] == "start"]
    ok(rc == 3 and starts == [("S2a", 1)] and "HARD STOP" in out, "orphans: a finding with nothing in flight stops the campaign (exit 3)",
       "rc %d %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)

    # ---- Law 1
    d, R, S = scratch(["S2a", "S5"])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5"], behave={"S2a:1": {"law1": True}})
    starts = [(e["rung"], e["rep"]) for e in evs if e["ev"] == "start"]
    ok(rc == 3 and starts == [("S2a", 1)] and "Law 1 DEFECT" in out, "law1: a Law 1 DEFECT after a run stops the campaign (a contract DEFECT does not)",
       "rc %d %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)
    d, R, S = scratch(["S2a"])
    rc, out, evs = campaign(R, S, "run", ["S2a"], files={"law1": ""})
    ok(rc == 3 and not evs and "refused to start" in out, "law1: a Law 1 DEFECT already in the record refuses to start", "rc %d\n%s" % (rc, out[-1500:]))
    shutil.rmtree(d)

    print("ladder_campaign_test: %d passed, %d failed" % (PASS[0], FAIL[0]))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())
