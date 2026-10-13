#!/usr/bin/env python3
"""make ladder-campaign-test (in make test): scripts/lib/ladder_campaign.py against stubs, no AWS.

Each scenario runs the real planner and driver in a scratch git repo holding the real committed
c1 specs of a few rungs, the real lever table, ladder_levers.py and quota_check.sh, a synthetic
record, and a scratch AZ list. `make run`, `make orphans`, `make g3-ladder` and quota_check.sh are
stubs (the driver's AK2_CAMPAIGN_* seams). The run stub writes a cohort dir as run-multi.sh does
(params from the real `ladder_levers.py spec-params --rep $AK2_LADDER_REP`, member manifests with
spec_sha256 and instance.az) and models run-multi's old orphan exit: rc 3 whenever another run is
in flight, with a clean record. The tables stub writes runs.tsv and its summary line. Scenarios:
  compat      a finished run whose spec differs only in a body change ladder.body-compat.tsv declares
              harmless for its classifier is done; an affected classifier, an undeclared change, a
              spec that differs elsewhere too, or a spec.json that is not the recorded bytes is rerun;
  plan        ordering (cost, then ladder order), rep 2 reversed, the done check (and why each
              record run is or is not counted: failed, a recorded defect, params, spec sha256,
              prefix not fetched, excluded by ladder_tables; an old global orphans_rc 1 is not
              disqualifying);
  skip        the run skips the done (rung, rep) and launches the rest;
  default     CONCURRENCY defaults to 1: never two runs in flight;
  normal      CONCURRENCY=4: the first launch runs alone, X never exceeds its limit (and reaches
              it), rep 2 after rep 1, AK2_LADDER_REP reaches params.rep, no launch while quota
              refuses, orphans after every run; runs whose make run exited 3 only because another
              run was alive are judged ok from their record (B1);
  capacity    x8g: one retry in the documented AZ, rep 2 in the spec's AZ; r8gd: no alternative,
              the rung stops; both rows reach g3_defects.tsv;
  failure     a failed run, a run in the wrong AZ, and a run ladder_tables excludes each stop
              their rung; the other rung carries on;
  orphans     informational with a run in flight; a hard stop with none;
  law1        a Law 1 DEFECT stops the campaign; one already there refuses to start; a g3-ladder
              crash (exit 1, no summary line) is a hard stop too (B2).
"""
import hashlib
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
import hashlib, json, os, random, subprocess, sys, time
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
EV = os.path.join(S, "events.jsonl")
def ev(kind, **kw):
    with open(EV, "a") as f:
        f.write(json.dumps(dict({"ev": kind, "rung": rung, "rep": rep, "az": az, "type": spec["resources"]["instance_type"],
                                 "t": time.time(), "env_rep": os.environ.get("AK2_LADDER_REP"), "env_az": os.environ.get("AK2_LAUNCH_AZ"),
                                 "dry": os.environ.get("DRY_RUN") or os.environ.get("MAKEFLAGS")}, **kw)) + "\n")
if b["r"] == "quota":
    ev("refused")
    print("quota_check: REFUSED: ...\nmake run (multi): refused before launch: 1 x t would exceed the region's on-demand vCPU quota (above)")
    sys.exit(2)
n = int(a["NODES"])
cid = "20261012-%s-abcdef0-%04x-n%d" % (time.strftime("%H%M%S"), random.randrange(65536), n)
print("make run (multi): cohort %s: %d x %s in %s -> s3://b/%s" % (cid, n, spec["resources"]["instance_type"], az, cid), flush=True)
os.makedirs("results/g3/%s" % cid)
ev("start")
inst_az = "us-west-2a" if b.get("wrong_az") else az
for k in range(n):
    os.makedirs("results/g3/%s-r%d" % (cid, k))
    json.dump({"cohort": {"id": cid}, "params": p, "spec": a["SPEC"],
               "spec_sha256": hashlib.sha256(open(a["SPEC"], "rb").read()).hexdigest(),
               "instance": {"type": spec["resources"]["instance_type"], "az": inst_az},
               "launch": {"instance_id": None if b["r"] == "capacity" else "i-%d" % k}},
              open("results/g3/%s-r%d/manifest.json" % (cid, k), "w"))
time.sleep(b["s"])
for flag in ("law1", "crash"):
    if b.get(flag):
        open(os.path.join(S, flag), "w").close()
if b.get("excluded"):
    open(os.path.join(S, "excluded"), "a").write(cid + "\n")
ex = {"ok": 0, "fail": 1, "capacity": None}[b["r"]]
if b["r"] == "capacity":
    open("results/g3/%s/rank-0.run.log" % cid, "w").write("An error occurred (InsufficientInstanceCapacity) ...\n")
# run-multi's old exit: the global orphan check fails while another run's instance is alive.
evs = [json.loads(l) for l in open(EV)]
others = sum(1 if e["ev"] == "start" else -1 for e in evs if e["ev"] in ("start", "end")) - 1
mem = [{"rank": k, "run_id": "%s-r%d" % (cid, k), "exit_code": ex, "cost_usd": None if ex is None else b["cost"],
        "instance_id": None if ex is None else "i-%d" % k, "own_gone": True} for k in range(n)]
json.dump({"cohort_id": cid, "spec": a["SPEC"], "params": p, "nodes": n, "az": az, "members": mem,
           "ended": "members done" if ex == 0 else "members done (fail fast: rank 0 exited 1)",
           "cost_usd": None if ex is None else b["cost"] * n, "prefix_fetched": True, "sweep_failures": [],
           "multipart_abort_failures": 0, "orphans_rc": 0, "orphans_scope": "own", "orphans_global_rc": 1 if others > 0 else 0},
          open("results/g3/%s/cohort.json" % cid, "w"))
rc = 0 if ex == 0 else 1
if rc == 0 and others > 0:
    rc = 3
ev("end", rc=rc)
sys.exit(rc)
'''

STUB_ORPHANS = r'''#!/usr/bin/env python3
import os, time
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
import glob, os, re, sys
S = os.environ["AK2T"]
out = dict(x.split("=", 1) for x in sys.argv[1:] if "=" in x)["OUT"]
if os.path.exists(os.path.join(S, "crash")):
    print("Traceback (most recent call last):\n  ...\nKeyError: 'x'", file=sys.stderr)
    raise SystemExit(1)
excl = set(open(os.path.join(S, "excluded")).read().split()) if os.path.exists(os.path.join(S, "excluded")) else set()
os.makedirs(out, exist_ok=True)
ids = [os.path.basename(d) for d in glob.glob("results/g3/2*") if re.match(r"^\d{8}-\d{6}-", os.path.basename(d))
       and not re.search(r"-n\d+-r\d+$", d)]
with open(os.path.join(out, "runs.tsv"), "w") as f:
    f.write("run_id\tgate\tin_attribution\n")
    for i in ids:
        f.write("%s\tg3\t%s\n" % (i, "no: DEFECT (contract): x" if i in excl else "yes"))
law1 = os.path.exists(os.path.join(S, "law1"))
if law1:
    print("ladder_tables: DEFECT (Law 1): SRR1: output sha256 differs", file=sys.stderr)
print("ladder_tables: DEFECT (contract): an older run (not Law 1)", file=sys.stderr)
print("ladder_tables: %d ladder run(s), 36 lever row(s), %d DEFECT(s) -> %s/" % (len(ids), 1 + law1, out), file=sys.stderr)
raise SystemExit(1)
'''

STUB_QUOTA = r'''#!/usr/bin/env python3
import json, os, sys, time
S = os.environ["AK2T"]
log = os.path.join(S, "quota.log")
n = sum(1 for _ in open(log)) if os.path.exists(log) else 0
refuse = int(open(os.path.join(S, "quota_refuse")).read()) if os.path.exists(os.path.join(S, "quota_refuse")) else 0
rc = 1 if n < refuse else 0
rd = lambda f: open(os.path.join(S, f)).read().split() if os.path.exists(os.path.join(S, f)) else []
typ = sys.argv[2]
perm, always = typ in rd("quota_perm"), typ in rd("quota_always")
if typ in rd("quota_busy"):   # refused while any run of this type is in flight (the campaign's own)
    EV = os.path.join(S, "events.jsonl")
    evs = [json.loads(l) for l in open(EV)] if os.path.exists(EV) else []
    always = sum(1 if e["ev"] == "start" else -1 for e in evs if e["ev"] in ("start", "end") and e["type"] == typ) > 0
if perm or always:
    rc = 1
open(log, "a").write("%f %d %s\n" % (time.time(), rc, " ".join(sys.argv[1:])))
if perm:    # the request alone exceeds the quota (quota_check.sh's JSON record and message)
    print('{"requested_vcpus": 384, "quota_vcpus": 256, "running_vcpus": 0}')
    print("quota_check: REFUSED: 4 x %s = 384 vCPU, plus 0 vCPU already running in 0 on-demand X instance(s) = 384 of the X "
          "on-demand quota L-7295265B (256 vCPU) in us-west-2. Lower NODES" % typ, file=sys.stderr)
elif always:   # refused only because other instances run
    print('{"requested_vcpus": 96, "quota_vcpus": 256, "running_vcpus": 192}')
    print("quota_check: REFUSED: 1 x %s = 96 vCPU, plus 192 vCPU already running in 2 on-demand X instance(s) = 288 of the X "
          "on-demand quota L-7295265B (256 vCPU) in us-west-2. Lower NODES" % typ, file=sys.stderr)
else:
    print("quota_check: %s: stub" % ("REFUSED" if rc else "ok"), file=sys.stderr)
raise SystemExit(rc)
'''


def spec_path(R, rung):
    return os.path.join(R, "runs", "g3-l-%s-c1.json" % rung.lower())


def params_of(rung, **over):
    sys.path.insert(0, os.path.join(HERE, "scripts", "lib"))
    import ladder_levers
    p = ladder_levers.spec_params(json.load(open(spec_path(HERE, rung))))
    p.update(over)
    return p


def done(rung, ok=True, cost=1.24, sha=None, **cj_over):
    """A record cohort (cohort.json, member r0 manifest) of rung, clean unless told otherwise."""
    p = cj_over.pop("params", None) or params_of(rung)
    s = sha or hashlib.sha256(open(spec_path(HERE, rung), "rb").read()).hexdigest()
    spec = "runs/g3-l-%s-c1.json" % rung.lower()
    cj = {"spec": spec, "params": p, "nodes": 1, "ended": "members done" if ok else "members done (fail fast: rank 0 exited 1)",
          "members": [{"rank": 0, "exit_code": 0 if ok else 1, "cost_usd": cost, "own_gone": True}], "cost_usd": cost,
          "prefix_fetched": True, "sweep_failures": [], "multipart_abort_failures": 0, "orphans_rc": 0}
    cj.update(cj_over)
    return cj, {"spec": spec, "spec_sha256": s, "params": p, "instance": {"az": "us-west-2b"}, "cohort": {}}


def old_spec(rung, body_edit=lambda b: b.replace("\nlad_one() {\n", "\nlad_one() {\n  # an older body\n", 1), spec_edit=None):
    """(spec.json bytes, from body sha256, to body sha256): the committed spec of rung with its body
    changed by body_edit (and the rest by spec_edit), as an older body would have generated it."""
    sys.path.insert(0, os.path.join(HERE, "scripts", "lib"))
    import ladder_body_compat as BC
    spec = json.load(open(spec_path(HERE, rung)))
    rest, block, body = BC.split_spec(spec)
    nb = body_edit(body)
    assert nb != body
    lines = nb[:-1].split("\n")
    i = lines.index("@PARAMS@")
    spec["command"][2] = "\n".join(lines[:i] + block + lines[i + 1:])
    if spec_edit:
        spec_edit(spec)
    return (json.dumps(spec, indent=2) + "\n").encode(), BC.sha256(nb), BC.sha256(body)


def done_old(rung, rd_spec, **kw):
    """done() for a run that ran the older spec rd_spec (its spec.json written in the member dir)."""
    cj, m0 = done(rung, sha=hashlib.sha256(rd_spec).hexdigest(), **kw)
    m0["_spec_json"] = rd_spec
    return cj, m0


def scratch(rungs, record=(), defects=(), excluded=(), compat=()):
    d = tempfile.mkdtemp(prefix="ladder-campaign-test.")
    R = os.path.join(d, "repo")
    for sub in ("scripts/lib", "scripts/g3", "runs", "results/g3", "stub"):
        os.makedirs(os.path.join(R, sub), exist_ok=True)
    for f in ("scripts/lib/ladder_campaign.py", "scripts/lib/ladder_levers.py", "scripts/lib/ladder_body_compat.py", "scripts/lib/quota_check.sh",
              "scripts/g3/ladder.levers.tsv", "scripts/g3/ladder-campaign.sh"):
        shutil.copy2(os.path.join(HERE, f), os.path.join(R, f))
    for r in rungs:
        shutil.copy2(spec_path(HERE, r), os.path.join(R, "runs"))
    with open(os.path.join(R, "scripts/lib/g3_defects.tsv"), "w") as f:
        f.write("run\tclass\tevidence\n")
        for row in defects:
            f.write("\t".join(row) + "\n")
    # Evidence manifests (committed below) for the scratch AZ list.
    with open(os.path.join(R, "scripts/g3/ladder.azs.tsv"), "w") as f:
        f.write("type\taz\tevidence\n")
        for t, z in (("x8g.24xlarge", "us-west-2c"), ("x8g.24xlarge", "us-west-2b"), ("r8gd.48xlarge", "us-west-2b")):
            e = os.path.join(R, "results", "ev", "%s-%s" % (t, z))
            os.makedirs(e)
            json.dump({"instance": {"type": t, "az": z}}, open(os.path.join(e, "manifest.json"), "w"))
            f.write("%s\t%s\tresults/ev/%s-%s/manifest.json\n" % (t, z, t, z))
    with open(os.path.join(R, "scripts/g3/ladder.body-compat.tsv"), "w") as f:
        f.write("# scratch\nfrom_body_sha256\tto_body_sha256\tcommit\tunaffected\taffected\tfunctions\treason\n")
        for row in compat:
            f.write("\t".join(row) + "\n")
    for rd, (cj, m0) in record:
        os.makedirs(os.path.join(R, "results", "g3", rd))
        os.makedirs(os.path.join(R, "results", "g3", rd + "-r0"))
        sj = m0.pop("_spec_json", None)
        if sj is not None:
            open(os.path.join(R, "results", "g3", rd + "-r0", "spec.json"), "wb").write(sj)
        json.dump(cj, open(os.path.join(R, "results", "g3", rd, "cohort.json"), "w"))
        json.dump(m0, open(os.path.join(R, "results", "g3", rd + "-r0", "manifest.json"), "w"))
    for name, body in (("run", STUB_RUN), ("orphans", STUB_ORPHANS), ("g3ladder", STUB_G3), ("quota", STUB_QUOTA)):
        p = os.path.join(R, "stub", name)
        open(p, "w").write(body)
        os.chmod(p, 0o755)
    S = os.path.join(d, "state")
    os.makedirs(S)
    json.dump({}, open(os.path.join(S, "behave.json"), "w"))
    if excluded:
        open(os.path.join(S, "excluded"), "w").write("\n".join(excluded) + "\n")
    subprocess.run("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t", shell=True, cwd=R, check=True)
    return d, R, S


def campaign(R, S, mode, rungs, reps=2, conc=None, limits="X=2,Standard=2", behave=None, files=None):
    if behave:
        json.dump(behave, open(os.path.join(S, "behave.json"), "w"))
    for k, v in (files or {}).items():
        open(os.path.join(S, k), "w").write(v)
    env = dict(os.environ, AK2T=S, AK2_CAMPAIGN_RUN=os.path.join(R, "stub", "run"),
               AK2_CAMPAIGN_ORPHANS=os.path.join(R, "stub", "orphans"), AK2_CAMPAIGN_G3LADDER=os.path.join(R, "stub", "g3ladder"),
               AK2_CAMPAIGN_QUOTA=os.path.join(R, "stub", "quota"), AK2_CAMPAIGN_POLL_S="0.05", AK2_CAMPAIGN_QUOTA_RETRY_S="0",
               DRY_RUN="", MAKEFLAGS="DRY_RUN=1")
    argv = ["python3", "scripts/lib/ladder_campaign.py", mode, "1", "--reps", str(reps), "--rungs", ",".join(rungs),
            "--family-limits", limits] + (["--concurrency", str(conc)] if conc else [])
    r = subprocess.run(argv, cwd=R, env=env, capture_output=True, text=True, timeout=300)
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
    # record_problems on a 2-node cohort where one member never launched (capacity): the AZ
    # check must name the missing AZ, not fail to sort None against a string.
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
    import ladder_campaign as LCm
    mans = [{"instance": {"az": "us-west-2b"}}, {"instance": {}}]
    try:
        why = LCm.record_problems("/nonexistent", {"ended": "members done"}, mans, "us-west-2b")
        ok(any("AZ" in w and "none" in w for w in why), "record_problems: a member with no AZ is named, not a crash", str(why))
    except TypeError as e:
        ok(False, "record_problems: a member with no AZ is named, not a crash", repr(e))
    rungs = ["S0-T1", "S1", "S2a", "S5", "S6"]
    # ---- plan: the done check
    rec = [("20261011-000001-aaaaaaa-0001-n1", done("S2a")),                                   # done, no params.rep
           ("20261011-000002-aaaaaaa-0002-n1", done("S5", ok=False)),                          # failed
           ("20261011-000003-aaaaaaa-0003-n1", done("S6")),                                    # a recorded defect
           ("20261011-000004-aaaaaaa-0004-n1", done("S1", params=params_of("S1", threads="96"))),   # params differ
           ("20261011-000005-aaaaaaa-0005-n1", done("S0-T1", cost=50.0, params=params_of("S0-T1", rep=2))),   # rep 2 done
           ("20261011-000006-aaaaaaa-0006-n1", done("S5", sha="0" * 64)),                      # another spec's bytes
           ("20261011-000007-aaaaaaa-0007-n1", done("S5", prefix_fetched=False)),              # prefix not fetched
           ("20261011-000008-aaaaaaa-0008-n1", done("S6")),                                    # excluded by ladder_tables
           ("20261011-000009-aaaaaaa-0009-n1", done("S1", cost=30.0, orphans_rc=1))]           # old global orphans rc 1: still done
    d, R, S = scratch(rungs, record=rec, defects=[("20261011-000003-aaaaaaa-0003-n1", "defect: x", "y")],
                      excluded=["20261011-000008-aaaaaaa-0008-n1"])
    rc, out, _ = campaign(R, S, "plan", rungs)
    rows = plan_rows(out)
    want = [(1, "S2a", "skip"), (1, "S5", "launch"), (1, "S6", "launch"), (1, "S1", "skip"), (1, "S0-T1", "launch"),
            (2, "S0-T1", "skip"), (2, "S1", "launch"), (2, "S6", "launch"), (2, "S5", "launch"), (2, "S2a", "launch")]
    ok(rc == 0 and rows == want, "plan: rep 1 cheapest first (measured, then estimate; ties in ladder order), rep 2 reversed, done skipped",
       "rc %d rows %s\n%s" % (rc, rows, out))
    for needle, what in (("rep 1 by default (no params.rep)", "a run without params.rep is rep 1"),
                         ("member exit r0=1", "a failed run"),
                         ("recorded defect (g3_defects.tsv 20261011-000003", "a recorded defect"),
                         ("params differ from runs/g3-l-s1-c1.json: threads '96' != 'vcpus'", "a params mismatch"),
                         ("spec_sha256 000000000000 is not the committed runs/g3-l-s5-c1.json's", "another spec's sha256"),
                         ("prefix not fetched", "an unfetched prefix"),
                         ("excluded by ladder_tables: no: DEFECT (contract)", "ladder_tables' exclusion")):
        ok(needle in out, "plan: the record lists %s" % what, out[-3000:])
    ok("000009-aaaaaaa-0009-n1           S1         rep 1 (rep 1 by default (no params.rep)): counted" in out,
       "plan: an old cohort's global orphans_rc 1 (a concurrent run) does not disqualify it; own_gone is the scoped verdict", out[-2000:])
    ok(not os.path.exists(os.path.join(R, "results", "g3", "ladder-campaign")) and not os.path.exists(os.path.join(S, "events.jsonl")),
       "plan: DRY_RUN writes nothing in the repo and launches nothing")
    shutil.rmtree(d)

    # ---- compat: finished runs whose spec differs from the committed one only in the body
    # (ladder.body-compat.tsv; scripts/lib/ladder_body_compat.py). Counted only where a row covers the
    # run's classifier and nothing but the body differs.
    rs = ["S2a", "S5", "S6", "O0", "O0b"]
    up, f1, t1 = old_spec("S2a")                                        # upstream, covered
    eng, _, _ = old_spec("O0b")                                         # ours-engine, covered
    plain, _, _ = old_spec("O0")                                        # ours-plain, affected: rerun
    ttl, _, _ = old_spec("S5", spec_edit=lambda sp: sp["lifecycle"].update(ttl="121m"))   # body and TTL differ: rerun
    unk, f2, _ = old_spec("S6", body_edit=lambda b: b.replace("\nlad_one() {\n", "\nlad_one() {\n  # undeclared\n", 1))  # no row
    lie = bytearray(old_spec("S2a")[0])                                 # spec.json is not the bytes the manifest names
    rec = [("20261011-000011-aaaaaaa-0011-n1", done_old("S2a", up)),
           ("20261011-000012-aaaaaaa-0012-n1", done_old("O0b", eng)),
           ("20261011-000013-aaaaaaa-0013-n1", done_old("O0", plain)),
           ("20261011-000014-aaaaaaa-0014-n1", done_old("S5", ttl)),
           ("20261011-000015-aaaaaaa-0015-n1", done_old("S6", unk)),
           ("20261011-000016-aaaaaaa-0016-n1", done_old("S2a", up, params=params_of("S2a", rep=2)))]
    rec[5][1][1]["_spec_json"] = bytes(lie) + b" "
    row = (f1, t1, "0" * 40, "upstream,ours-engine", "ours-plain", "lad_one", "test")
    d, R, S = scratch(rs, record=rec, compat=[row])
    rc, out, _ = campaign(R, S, "plan", rs)
    got = {(rep, rung): a for rep, rung, a in plan_rows(out)}
    ok(rc == 0 and got.get((1, "S2a")) == "skip" and got.get((1, "O0b")) == "skip",
       "compat: an upstream and an ours-engine run whose spec differs only in a declared body change are done", "rc %d %s\n%s" % (rc, got, out[-3000:]))
    ok(got.get((1, "O0")) == "launch" and "does not declare that change harmless for ours-plain" in out,
       "compat: the same body change on ours-plain (an affected classifier) forces a rerun", out[-3000:])
    ok(got.get((1, "S5")) == "launch" and "spec differs beyond the body: lifecycle.ttl" in out,
       "compat: a spec that differs in the body and elsewhere (TTL) forces a rerun", out[-3000:])
    ok(got.get((1, "S6")) == "launch" and ("(%s -> " % f2[:12]) in out and "does not declare that change harmless for upstream" in out,
       "compat: a body change with no row forces a rerun", out[-3000:])
    ok(got.get((2, "S2a")) == "launch" and "20261011-000016-aaaaaaa-0016-n1/../" not in out and "is not that spec" in out,
       "compat: a run whose spec.json is not the bytes of its recorded spec_sha256 forces a rerun", out[-3000:])
    ok("ladder.body-compat.tsv line(s) 3: upstream unaffected" in out and "body-compatible spec (ladder.body-compat.tsv)" in out,
       "compat: the plan says why a body-only difference was accepted, citing the row", out[-3000:])
    shutil.rmtree(d)
    d, R, S = scratch(["S2a"], record=[rec[0]], compat=[(f1, t1, "0" * 40, "ours-engine", "upstream,ours-plain", "lad_one", "test")])
    rc, out, _ = campaign(R, S, "plan", ["S2a"])
    ok(dict(((r, g), a) for r, g, a in plan_rows(out)).get((1, "S2a")) == "launch",
       "compat: a row that does not cover upstream does not keep the upstream run (mutation of the row)", out[-2000:])
    shutil.rmtree(d)

    # ---- skip (run mode): S2a rep 1 is done
    d, R, S = scratch(["S2a", "S5"], record=[("20261011-000001-aaaaaaa-0001-n1", done("S2a"))])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5"])
    starts = [(e["rung"], e["rep"]) for e in evs if e["ev"] == "start"]
    ok(rc == 0 and sorted(starts) == [("S2a", 2), ("S5", 1), ("S5", 2)], "skip: the done S2a rep 1 is not launched; the rest are",
       "rc %d starts %s\n%s" % (rc, starts, out[-2000:]))
    tsv = campaign_tsv(R)
    ok(any(r[1] == "S2a" and r[2] == "1" and r[7] == "skip" and r[4] == "results/g3/20261011-000001-aaaaaaa-0001-n1" for r in tsv),
       "skip: the campaign log records the skip and the run that did it", tsv)
    shutil.rmtree(d)

    # ---- default: one run at a time
    rs = ["S1", "S2a", "S5"]
    d, R, S = scratch(rs)
    rc, out, evs = campaign(R, S, "run", rs, behave={"S2a:1": {"s": 0.3}})
    ok(rc == 0 and len([e for e in evs if e["ev"] == "start"]) == 6 and concurrency(evs, lambda e: True) == 1,
       "default: CONCURRENCY=1, never two runs in flight (peak %d)" % concurrency(evs, lambda e: True), "rc %d\n%s" % (rc, out[-2000:]))
    ok("CONCURRENCY=1 (runs in flight at once)" in out, "default: the plan states CONCURRENCY=1")
    shutil.rmtree(d)

    # ---- quota: a request over the quota on its own stops its rung at once (permanent), and the
    # family is not held up: S5 (the same X family) is asked in the same pass; S1 (r8gd) runs.
    rs = ["S1", "S2a", "S5"]
    d, R, S = scratch(rs)
    rc, out, evs = campaign(R, S, "run", rs, files={"quota_perm": "x8g.24xlarge"})
    starts = sorted((e["rung"], e["rep"]) for e in evs if e["ev"] == "start")
    q = [l.split() for l in open(os.path.join(S, "quota.log"))]
    xq = [x for x in q if x[3] == "x8g.24xlarge"]
    ok(rc == 1 and starts == [("S1", 1), ("S1", 2)] and len(xq) == 2,
       "quota-permanent: S2a and S5 (each over the X quota on its own) stop at their first refusal, without waiting; S1 runs (exit 1)",
       "rc %d starts %s x8g quota calls %d\n%s" % (rc, starts, len(xq), out[-2000:]))
    ok("exceeds the X on-demand quota of 256 vCPU on its own (permanent" in out and "not launched: S2a rep 2" in out,
       "quota-permanent: the stop is reported with the vCPUs, and the rung's later rep is not launched", out[-2000:])
    shutil.rmtree(d)
    # ---- quota: a refusal because other instances run is waited for, but only up to the bound.
    d, R, S = scratch(rs)
    os.environ["AK2_CAMPAIGN_QUOTA_MAX_WAIT_S"] = "0.4"
    try:
        rc, out, evs = campaign(R, S, "run", rs, files={"quota_always": "x8g.24xlarge"})
    finally:
        del os.environ["AK2_CAMPAIGN_QUOTA_MAX_WAIT_S"]
    starts = sorted((e["rung"], e["rep"]) for e in evs if e["ev"] == "start")
    xq = [l.split() for l in open(os.path.join(S, "quota.log")) if " x8g.24xlarge " in l]
    ok(rc == 1 and starts == [("S1", 1), ("S1", 2)] and len(xq) > 2 and "over the 0 s bound" in out,
       "quota-wait: refused for running instances, S2a is asked again (%d calls) until the 0.4 s bound, then stops; S1 runs" % len(xq),
       "rc %d starts %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)

    # ---- quota: refused while the campaign's own x8g run is in flight, longer than the bound: that
    # time is the schedule, not the quota, so S5 is not stopped; it launches once S2a ends.
    d, R, S = scratch(rs)
    os.environ["AK2_CAMPAIGN_QUOTA_MAX_WAIT_S"] = "0.3"
    try:
        rc, out, evs = campaign(R, S, "run", rs, conc=3, behave={"S2a:1": {"s": 1.5}, "S2a:2": {"s": 1.5}, "S5:1": {"s": 1.5},
                                                                 "S5:2": {"s": 1.5}}, files={"quota_busy": "x8g.24xlarge"})
    finally:
        del os.environ["AK2_CAMPAIGN_QUOTA_MAX_WAIT_S"]
    starts = sorted((e["rung"], e["rep"]) for e in evs if e["ev"] == "start")
    busy = [l for l in open(os.path.join(S, "quota.log")) if " x8g.24xlarge " in l and l.split()[1] == "1"]
    ok(rc == 0 and len(starts) == 6 and len(busy) >= 2 and "over the" not in out,
       "quota-siblings: %d refusals while the campaign's own x8g run was in flight (over 1 s against a 0.3 s bound) do not "
       "stop S5; all 6 launch" % len(busy), "rc %d starts %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)

    # ---- normal, CONCURRENCY=4
    rs = ["S1", "S2a", "S5", "S6", "S0-T1"]
    d, R, S = scratch(rs)
    beh = {"S2a:1": {"s": 0.6}, "S5:1": {"s": 1.2}, "S6:1": {"s": 1.2}, "S1:1": {"s": 0.8}, "S0-T1:1": {"s": 0.8}}
    rc, out, evs = campaign(R, S, "run", rs, conc=4, behave=beh, files={"quota_refuse": "2"})
    starts = [e for e in evs if e["ev"] == "start"]
    ok(rc == 0 and len(starts) == 10, "normal: exit 0, 10 launches", "rc %d %d starts\n%s" % (rc, len(starts), out[-3000:]))
    first = sorted(starts, key=lambda e: e["t"])[0]
    ok((first["rung"], first["rep"]) == ("S2a", 1) and all(e["t"] >= t_of(evs, "end", "S2a", 1) for e in starts if e is not first),
       "normal: the cheapest (S2a rep 1) runs first and alone", [(e["rung"], e["rep"]) for e in sorted(starts, key=lambda e: e["t"])])
    px = concurrency(evs, lambda e: e["type"].startswith("x8g"))
    ok(px == 2, "normal: the X family reaches its limit of 2 and never exceeds it (peak %d)" % px)
    ok(concurrency(evs, lambda e: True) <= 4, "normal: never more than CONCURRENCY=4 in flight")
    ok(all(t_of(evs, "start", r, 2) >= t_of(evs, "end", r, 1) for r in rs), "normal: every rung's rep 2 starts after its rep 1 ends")
    ok(all(e["env_rep"] == str(e["rep"]) and not e["dry"] for e in starts),
       "normal: AK2_LADDER_REP is each launch's rep (DRY_RUN and the parent make's MAKEFLAGS not passed on)")
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
    rc3 = [e for e in evs if e["ev"] == "end" and e.get("rc") == 3]
    ok(rc3 and len(tsv) == 10 and all(r[7] == "ok" and r[4].startswith("results/g3/2026") and r[6] == "1.0" for r in tsv),
       "normal: %d run(s) whose make run exited 3 only for another run's instance are ok from the record (B1); log rows complete" % len(rc3), tsv)
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

    # ---- failure: a failed run, a run in the wrong AZ, a run ladder_tables excludes
    for name, beh, needle in (("failed", {"S5:1": {"r": "fail"}}, "member exit r0=1"),
                              ("wrong AZ", {"S5:1": {"wrong_az": True}}, "instance AZ us-west-2a, requested us-west-2b"),
                              ("excluded", {"S5:1": {"excluded": True}}, "excluded by ladder_tables")):
        d, R, S = scratch(["S5", "S6"])
        rc, out, evs = campaign(R, S, "run", ["S5", "S6"], behave=beh)
        starts = sorted((e["rung"], e["rep"]) for e in evs if e["ev"] == "start")
        ok(rc == 1 and starts == [("S5", 1), ("S6", 1), ("S6", 2)] and needle in out,
           "failure (%s): S5 stops, its rep 2 is not launched; S6 carries on" % name, "rc %d %s\n%s" % (rc, starts, out[-2000:]))
        shutil.rmtree(d)

    # ---- orphans: informational with a run in flight; a hard stop with none
    d, R, S = scratch(["S2a", "S5", "S6"])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5", "S6"], reps=1, conc=2,
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

    # ---- Law 1 and g3-ladder judgement
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
    d, R, S = scratch(["S2a", "S5"])
    rc, out, evs = campaign(R, S, "run", ["S2a", "S5"], behave={"S2a:1": {"crash": True}})
    starts = [(e["rung"], e["rep"]) for e in evs if e["ev"] == "start"]
    ok(rc == 3 and starts == [("S2a", 1)] and "without its summary line: Law 1 not judged" in out,
       "law1: a g3-ladder crash (exit 1, no summary line) is a hard stop, not a pass (B2)", "rc %d %s\n%s" % (rc, starts, out[-2000:]))
    shutil.rmtree(d)
    d, R, S = scratch(["S2a"])
    rc, out, _ = campaign(R, S, "plan", ["S2a"], files={"crash": ""})
    ok(rc == 3 and "without its summary line" in out, "law1: DRY_RUN refuses a plan when g3-ladder cannot judge", "rc %d\n%s" % (rc, out[-1000:]))
    shutil.rmtree(d)

    print("ladder_campaign_test: %d passed, %d failed" % (PASS[0], FAIL[0]))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())
