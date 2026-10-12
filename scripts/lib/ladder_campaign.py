#!/usr/bin/env python3
"""make ladder-campaign (docs/ladder.md, "The campaign"): every committed ladder spec of one cohort,
REPS times, cheapest first, through make run, with the after-run checks.

  ladder_campaign.py plan COHORT [options]   print the plan for the record; no AWS, nothing written in the repo
  ladder_campaign.py run  COHORT [options]   the campaign (scripts/g3/ladder-campaign.sh)

Options (from the make variables): --reps N (2), --rungs S1,S2a (a subset, by rung name),
--concurrency N (1: runs in flight at once), --family-limits X=2,Standard=1 (instances in flight
per on-demand quota family; default 2 for every family; only binding when CONCURRENCY > 1).

The plan:
  - specs: every committed runs/g3-l-*-c<COHORT>.json whose PARAMS block names that cohort;
  - rep 1 is ordered by cost, cheapest first: the median billed cost_usd of the rung's done runs
    at this cohort where any exist (measured), else the spec's cost_limit x NODES (the generator's
    TTL x on-demand price, an estimate). Ties go in ladder order (ladder.levers.tsv);
  - rep 2 is rep 1 reversed (rep k: reversed when k is even);
  - a (rung, cohort, rep) that already has a done run is skipped. Done: the run's spec_sha256 is
    the committed spec's sha256 (or its spec.json differs from the committed spec only in the body,
    and scripts/g3/ladder.body-compat.tsv declares that body change harmless for the run's
    classifier: scripts/lib/ladder_body_compat.py) and its params match the spec's (all keys but source, rep and
    rep_source); the record is clean (record_problems: every member exit 0, own_gone, ended
    "members done" without fail fast, the prefix fetched, no sweep or abort failures, the scoped
    orphan check 0); ladder_tables keeps it in the attribution; not in scripts/lib/g3_defects.tsv.
    Its rep is params.rep, or 1 when the run has none.

The run: one launch settles before the next; NODES = WANT_N; AK2_LADDER_REP=<rep> reaches
params.rep. A launch waits for: CONCURRENCY, its family's limit, the first launch's success, the
rung's earlier rep, and quota_check.sh (exit 1: wait; exit 2: stop launching). After each run: make
orphans (informational while other campaign runs are in flight, a hard stop when none is), make
g3-ladder (its summary line must be there; a Law 1 DEFECT stops the campaign), then the outcome is
judged from the record, not from make run's exit, and logged in results/g3/ladder-campaign/<ts>.tsv.
InsufficientInstanceCapacity: a capacity row (appended to scripts/lib/g3_defects.tsv when the
campaign ends) and one retry in an AZ that scripts/g3/ladder.azs.tsv documents; any other failure
stops the rung. Nothing is committed.

Test seams (scripts/tests/ladder_campaign_test.py): AK2_CAMPAIGN_RUN, AK2_CAMPAIGN_ORPHANS,
AK2_CAMPAIGN_G3LADDER (gets OUT=<dir>), AK2_CAMPAIGN_QUOTA (command prefixes), AK2_CAMPAIGN_POLL_S
(10 s), AK2_CAMPAIGN_QUOTA_RETRY_S (60 s: a refused family is not asked again sooner),
AK2_CAMPAIGN_SETTLE_S (900 s).
"""
import csv
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True   # a __pycache__ under scripts/ would make run.sh refuse the tree
sys.path.insert(0, HERE)
import ladder_levers as LL  # noqa: E402
import ladder_body_compat as BC  # noqa: E402

DEFECTS = os.path.join(ROOT, "scripts", "lib", "g3_defects.tsv")
CAMPAIGN_DIR = os.path.join(ROOT, "results", "g3", "ladder-campaign")
IGNORED_KEYS = ("source", "rep", "rep_source")
RUN_PATHS = ["scripts", "runs", "cmd", "internal", "upstream", "go.mod", "go.sum", "Makefile"]   # run.sh's clean-tree check
RUN_DIR_RE = re.compile(r"^\d{8}-\d{6}-")      # a run or cohort id, any year
MEMBER_RE = re.compile(r"-n\d+-r\d+$")
SUMMARY_RE = re.compile(r"^ladder_tables: \d+ ladder run\(s\), .*\d+ DEFECT\(s\) -> ", re.M)
DEFAULT_FAMILY_LIMIT = 2


def say(msg):
    print("ladder-campaign: %s" % msg, flush=True)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def rel(p):
    return os.path.relpath(p, ROOT)


def git(*a):
    return subprocess.run(["git", "-C", ROOT] + list(a), capture_output=True, text=True)


def sha256(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def family_of(itype):
    """The on-demand quota family, from quota_check.sh's own mapping (no AWS call)."""
    r = subprocess.run([os.path.join(ROOT, "scripts", "lib", "quota_check.sh"), "us-west-2", itype, "1"],
                       capture_output=True, text=True, env=dict(os.environ, AK2_QUOTA_FAMILY_ONLY="1"))
    if r.returncode != 0:
        raise SystemExit("ladder-campaign: no quota family for %s: %s" % (itype, r.stderr.strip()))
    return r.stdout.strip().split(" ", 1)[1].split("(")[0]


def read_defects(path=DEFECTS):
    out = {}
    if os.path.isfile(path):
        with open(path) as f:
            for i, line in enumerate(f):
                c = line.rstrip("\n").split("\t")
                if i == 0 or not c[0]:
                    continue
                out[c[0]] = c[1] if len(c) > 1 else ""
    return out


def comparable(p):
    return {k: v for k, v in (p or {}).items() if k not in IGNORED_KEYS}


def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def cmd(envname, default):
    v = os.environ.get(envname)
    return shlex.split(v) if v else default


# ---------------------------------------------------------------- ladder_tables

def run_tables(out_dir, log):
    """make g3-ladder OUT=<out_dir>, output to log. Returns (judged, law1_lines, in_attribution, rc).
    judged is False when the summary line is missing (a crash also exits 1, like a DEFECT)."""
    with open(log, "w") as f:
        rc = subprocess.run(cmd("AK2_CAMPAIGN_G3LADDER", ["make", "g3-ladder"]) + ["OUT=" + out_dir],
                            stdout=f, stderr=subprocess.STDOUT, cwd=ROOT,
                            env={k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}).returncode
    with open(log, errors="replace") as f:
        text = f.read()
    # The summary line is the last thing ladder_tables prints (after every table is written), so it
    # is the judgement; the exit is not: a DEFECT and a traceback both exit 1 (make reports 2).
    judged = rc in (0, 1, 2) and bool(SUMMARY_RE.search(text))
    law1 = [l for l in text.splitlines() if "DEFECT (Law 1)" in l]
    attr = {}
    p = os.path.join(out_dir, "runs.tsv")
    if judged and os.path.isfile(p):
        with open(p) as f:
            for r in csv.DictReader(f, delimiter="\t"):
                attr[r.get("run_id", "")] = r.get("in_attribution", "")
    return judged, law1, attr, rc


# ---------------------------------------------------------------- the record

def member_manifests(cdir, cj):
    cid = os.path.basename(cdir)
    return [load_json(os.path.join(os.path.dirname(cdir), "%s-r%d" % (cid, k), "manifest.json")) for k in range(cj.get("nodes") or 0)]


def record_problems(cdir, cj, mans, want_az=None):
    """Why a cohort's record is not clean (empty if it is): what a done run must satisfy, judged
    from cohort.json and the member manifests, never from make run's exit."""
    why = []
    members = cj.get("members") or []
    ended = cj.get("ended") or ""
    if not ended.startswith("members done") or "fail fast" in ended:
        why.append("ended %r" % ended)
    if not members or len(members) != cj.get("nodes"):
        why.append("%d of %s members recorded" % (len(members), cj.get("nodes")))
    bad = [m for m in members if m.get("exit_code") != 0]
    if bad:
        why.append("member exit %s" % ",".join("r%s=%s" % (m.get("rank"), m.get("exit_code")) for m in bad))
    gone = [m for m in members if m.get("own_gone") is not True]
    if gone:
        why.append("own_gone not true for %s" % ",".join("r%s" % m.get("rank") for m in gone))
    if cj.get("prefix_fetched") is not True:
        why.append("prefix not fetched")
    if cj.get("sweep_failures"):
        why.append("sweep failures")
    if cj.get("multipart_abort_failures"):
        why.append("multipart abort failures")
    # orphans_rc is the scoped check's only where run-multi says so (orphans_scope own); before
    # that it was the global check, which a concurrent run fails, and the members' own_gone above
    # is the scoped verdict.
    if cj.get("orphans_scope") == "own" and cj.get("orphans_rc") != 0:
        why.append("scoped orphan check rc %s" % cj.get("orphans_rc"))
    if any(m is None for m in mans):
        why.append("a member manifest is missing")
    if want_az:
        azs = sorted({(m.get("instance") or {}).get("az") for m in mans if m})
        if azs != [want_az]:
            why.append("instance AZ %s, requested %s" % (",".join(str(a) for a in azs), want_az))
    return why


def scan_record(defects, spec_sha, compat=None):
    """Every ladder run under results/<gate>/<yyyymmdd>-* (cohort dirs, and single runs that are
    not cohort members) with the reasons it is not done (attribution added by plan)."""
    runs = []
    for d in sorted(glob.glob(os.path.join(ROOT, "results", "*", "*"))):
        b = os.path.basename(d)
        if not os.path.isdir(d) or not RUN_DIR_RE.match(b) or MEMBER_RE.search(b):
            continue
        cj = load_json(os.path.join(d, "cohort.json"))
        if cj is not None:
            mans = member_manifests(d, cj)
            params = cj.get("params") or ((mans[0] or {}).get("params") if mans else None)
            if not params or not params.get("rung"):
                continue
            ids = [b] + [m.get("run_id") for m in cj.get("members") or [] if m.get("run_id")]
            why = record_problems(d, cj, mans)
            ssha = (mans[0] or {}).get("spec_sha256") if mans else None
            spec = cj.get("spec") or ((mans[0] or {}).get("spec") if mans else None)
            cost, kind = cj.get("cost_usd"), "cohort"
        else:
            m = load_json(os.path.join(d, "manifest.json"))
            if m is None or m.get("cohort") or not (m.get("params") or {}).get("rung"):
                continue
            params, ids, kind = m["params"], [b], "single"
            ex = (m.get("task") or {}).get("exit_code")
            why = [] if ex == 0 else ["task exit %s" % ex]
            if (m.get("orphan_check") or {}).get("own_gone") is not True:
                why.append("own_gone not true")
            ssha, spec, cost = m.get("spec_sha256"), m.get("spec"), m.get("cost_usd")
        note = None
        if spec in spec_sha and ssha != spec_sha[spec]:
            # A body change the record's run predates: counted only where the run's own spec.json
            # differs from the committed spec in nothing but the body, and ladder.body-compat.tsv
            # declares that change harmless for the run's classifier.
            rdir = os.path.join(os.path.dirname(d), "%s-r0" % b) if kind == "cohort" else d
            rp = os.path.join(rdir, "spec.json")
            rs = load_json(rp)
            if rs is None or sha256(rp) != ssha:
                why.append("spec_sha256 %s is not the committed %s's %s (and %s is %s)" % (
                    (ssha or "none")[:12], spec, spec_sha[spec][:12], rel(rp), "missing" if rs is None else "not that spec"))
            else:
                ok, v = BC.verdict(rs, load_json(os.path.join(ROOT, spec)), params.get("classifier"), compat)
                if ok:
                    note = "spec_sha256 %s, not the committed %s's %s: %s" % (ssha[:12], spec, spec_sha[spec][:12], v)
                else:
                    why.append("spec_sha256 %s is not the committed %s's %s: %s" % (ssha[:12], spec, spec_sha[spec][:12], v))
        hit = [i for i in ids if i in defects]
        if hit:
            why.append("recorded defect (g3_defects.tsv %s: %s)" % (hit[0], defects[hit[0]]))
        rep = params.get("rep", 1)
        try:
            rep = int(rep)
        except (TypeError, ValueError):
            why.append("params rep %r" % (rep,))
        runs.append({"dir": rel(d), "id": b, "kind": kind, "params": params, "rung": params["rung"],
                     "cohort": params.get("cohort"), "rep": rep,
                     "rep_basis": "params.rep" if "rep" in params else "rep 1 by default (no params.rep)",
                     "ok": not why, "why": why, "cost": cost, "note": note})
    return runs


# ---------------------------------------------------------------- the plan

def load_specs(cohort, rungs=None):
    """The committed ladder specs of this cohort, in ladder order: (specs, notes)."""
    order = {r["rung"]: i for i, r in enumerate(LL.load(LL.TSV))}
    tracked = set(git("ls-files", "runs").stdout.split())
    notes, specs = [], []
    for f in sorted(glob.glob(os.path.join(ROOT, "runs", "g3-l-*-c%d.json" % cohort))):
        rp = rel(f)
        if rp not in tracked:
            notes.append("%s: not committed, not planned (run.sh refuses it)" % rp)
            continue
        spec = load_json(f)
        p = LL.spec_params(spec) if spec else None
        if not p:
            notes.append("%s: no ladder PARAMS block, not planned" % rp)
            continue
        if p.get("cohort") != cohort:
            notes.append("%s: PARAMS cohort %s, not %d; not planned" % (rp, p.get("cohort"), cohort))
            continue
        rung = p["rung"]
        if rung not in order:
            raise SystemExit("ladder-campaign: %s names rung %s, which is not in ladder.levers.tsv" % (rp, rung))
        nodes = p.get("want_n")
        if not isinstance(nodes, int) or nodes != p.get("replicas", 0) * p.get("shards", 0):
            raise SystemExit("ladder-campaign: %s: WANT_N %r is not REPLICAS x SHARDS" % (rp, nodes))
        itype = spec["resources"]["instance_type"]
        specs.append({"rung": rung, "spec": rp, "sha256": sha256(f), "params": p, "nodes": nodes, "type": itype,
                      "az": spec["placement"]["availability_zone"], "region": spec["env"]["AK2_REGION"],
                      "ttl": spec["lifecycle"]["ttl"], "cost_limit": float(spec["lifecycle"]["cost_limit"]),
                      "family": family_of(itype), "ladder_index": order[rung]})
    if rungs:
        want = {r.lower() for r in rungs}
        unknown = sorted(want - {s["rung"].lower() for s in specs})
        if unknown:
            raise SystemExit("ladder-campaign: RUNGS %s: no committed c%d spec" % (",".join(unknown), cohort))
        specs = [s for s in specs if s["rung"].lower() in want]
    specs.sort(key=lambda s: s["ladder_index"])
    return specs, notes


def plan(cohort, reps, rungs, attr):
    """attr: ladder_tables' in_attribution by run id (a done run must be 'yes')."""
    specs, notes = load_specs(cohort, rungs)
    record = [r for r in scan_record(read_defects(), {s["spec"]: s["sha256"] for s in specs}, BC.load())
              if r["cohort"] == cohort and r["rung"] in {s["rung"] for s in specs}]
    by_rung = {s["rung"]: s for s in specs}
    for r in record:
        a, b = comparable(by_rung[r["rung"]]["params"]), comparable(r["params"])
        diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        if diff:
            r["why"].append("params differ from %s: %s" % (by_rung[r["rung"]]["spec"], ", ".join(
                "%s %r != %r" % (k, b.get(k), a.get(k)) for k in diff)))
        ia = attr.get(r["id"])
        if ia is None:
            r["why"].append("not in ladder_tables' runs.tsv")
        elif ia != "yes":
            r["why"].append("excluded by ladder_tables: %s" % ia[:160])
        r["ok"] = not r["why"]
    for s in specs:
        good = [r for r in record if r["rung"] == s["rung"] and r["ok"] and isinstance(r["cost"], (int, float))]
        if good:
            s["cost"] = round(statistics.median(r["cost"] for r in good), 6)
            s["basis"] = "measured: median billed $ of %d run(s)" % len(good)
        else:
            s["cost"] = round(s["cost_limit"] * s["nodes"], 6)
            s["basis"] = "estimate: cost_limit x %d node(s) (TTL %s x price)" % (s["nodes"], s["ttl"])
    rep1 = sorted(specs, key=lambda s: (s["cost"], s["ladder_index"]))
    items = []
    for rep in range(1, reps + 1):
        for s in (rep1 if rep % 2 else list(reversed(rep1))):
            done = [r for r in record if r["rung"] == s["rung"] and r["rep"] == rep and r["ok"]]
            it = dict(s, rep=rep, order=len(items) + 1, az_override=None, retried=False, tried_azs=[s["az"]])
            if done:
                it["action"] = "skip"
                it["why"] = "done: %s (%s, params match, clean record, in the attribution, not a recorded defect, %s)" % (
                    done[0]["dir"], "body-compatible spec (ladder.body-compat.tsv)" if done[0].get("note") else "spec sha256 matches",
                    done[0]["rep_basis"])
                it["done_dir"] = done[0]["dir"]
            else:
                it["action"] = "launch"
            items.append(it)
    return items, record, notes


def print_plan(cohort, reps, items, record, notes, conc, limits, out=None):
    w = out or (lambda l: print(l, flush=True))
    w("ladder-campaign: cohort %d, REPS=%d: %d committed spec(s) runs/g3-l-*-c%d.json; rep 1 cheapest first "
      "(measured billed $ where a done run exists, else cost_limit x nodes), ties in ladder order; "
      "rep 2 reversed" % (cohort, reps, len({i['rung'] for i in items}), cohort))
    w("ladder-campaign: CONCURRENCY=%d (runs in flight at once)%s; quota_check.sh before every launch" % (
        conc, "" if conc == 1 else "; family limits (instances): %s, others %d; the first launch runs alone" % (
            ", ".join("%s=%d" % kv for kv in sorted(limits.items())), DEFAULT_FAMILY_LIMIT)))
    for n in notes:
        w("ladder-campaign: note: %s" % n)
    w("%-5s %-3s %-11s %-30s %-5s %-14s %-10s %-8s %10s  %-46s %s" % (
        "order", "rep", "rung", "spec", "nodes", "type", "az", "family", "cost_usd", "basis", "action"))
    for i in items:
        w("%-5d %-3d %-11s %-30s %-5d %-14s %-10s %-8s %10.2f  %-46s %s" % (
            i["order"], i["rep"], i["rung"], i["spec"], i["nodes"], i["type"], i["az"], i["family"], i["cost"],
            i["basis"], "launch" if i["action"] == "launch" else "skip: " + i["why"]))
    w("ladder-campaign: the record, ladder runs of these rungs at c%d:" % cohort)
    if not record:
        w("  (none)")
    for r in record:
        w("  %-52s %-10s rep %d (%s): %s" % (r["dir"], r["rung"], r["rep"], r["rep_basis"],
                                             ("counted" + ("; " + r["note"] if r.get("note") else "")) if r["ok"]
                                             else "not counted: " + "; ".join(r["why"])))
    la = [i for i in items if i["action"] == "launch"]
    w("ladder-campaign: %d launch(es), %d skipped; cost basis of the launches $%.2f (an upper bound where estimated)" % (
        len(la), len(items) - len(la), sum(i["cost"] for i in la)))


# ---------------------------------------------------------------- the run

class Campaign:
    def __init__(self, cohort, reps, items, conc, limits, ts):
        self.cohort, self.reps, self.conc, self.limits, self.ts = cohort, reps, conc, limits, ts
        self.queue = [i for i in items if i["action"] == "launch"]
        self.skipped = [i for i in items if i["action"] == "skip"]
        self.inflight = []          # dicts: item, proc, log, cohort_id, settled, t0, tail
        self.blocked = {}           # rung -> reason
        self.dropped = []           # (item, reason)
        self.outcomes = []
        self.pending_defects = []
        self.stop = None            # why no further launches happen
        self.hard = False           # orphans with nothing in flight, Law 1, a check that cannot judge, a signal
        self.any_ok = False
        self.waiting = None
        self.attr = {}
        self.poll = float(os.environ.get("AK2_CAMPAIGN_POLL_S", "10"))
        self.quota_retry = float(os.environ.get("AK2_CAMPAIGN_QUOTA_RETRY_S", "60"))
        self.quota_next = {}        # family -> time before which a refused family is not asked again
        # (rung, rep) -> (seconds refused for others' instances, time of the last refusal): the bounded
        # quota wait. Time while the campaign's own runs of that family are in flight is not counted.
        self.quota_waited = {}
        self.quota_max_wait = float(os.environ.get("AK2_CAMPAIGN_QUOTA_MAX_WAIT_S", str(6 * 3600)))
        self.settle_s = float(os.environ.get("AK2_CAMPAIGN_SETTLE_S", "900"))
        self.dir = os.path.join(CAMPAIGN_DIR, ts)
        self.tables = os.path.join(self.dir, "tables")
        self.tsv = os.path.join(CAMPAIGN_DIR, ts + ".tsv")
        self.defects_tsv = os.path.join(CAMPAIGN_DIR, ts + ".defects.tsv")
        self.n_checks = 0
        os.makedirs(self.dir, exist_ok=True)
        with open(self.tsv, "w") as f:
            f.write("t\trung\trep\taz\trun_dir\texit\tcost_usd\tclass\tnote\n")

    def row(self, it, run_dir, rc, cost, cls, note):
        with open(self.tsv, "a") as f:
            f.write("\t".join(str(x) for x in (now_iso(), it["rung"], it["rep"], it.get("az_override") or it["az"],
                                               run_dir or "-", "-" if rc is None else rc,
                                               "-" if cost is None else cost, cls, note.replace("\t", " "))) + "\n")

    def halt(self, why, hard=False):
        if self.stop is None:
            self.stop = why
            say("STOP: no further launches: %s" % why)
        self.hard = self.hard or hard

    # -- checks
    def tree_dirty(self):
        r = git("status", "--porcelain", "--", *RUN_PATHS)
        return r.stdout.rstrip() if r.returncode == 0 else "git status failed: " + r.stderr.strip()

    def quota(self, it):
        """(rc, its last stderr line, (requested vCPUs, quota vCPUs) or None): quota_check.sh's JSON
        record on stdout, else its REFUSED/ok message (`= <req> vCPU, plus ... quota <code> (<q> vCPU)`)."""
        c = cmd("AK2_CAMPAIGN_QUOTA", [os.path.join(ROOT, "scripts", "lib", "quota_check.sh")])
        r = subprocess.run(c + [it["region"], it["type"], str(it["nodes"])], capture_output=True, text=True, cwd=ROOT)
        line = (r.stderr.strip().splitlines() or [""])[-1]
        need = None
        for l in r.stdout.splitlines():
            try:
                j = json.loads(l)
                need = (int(j["requested_vcpus"]), int(j["quota_vcpus"]))
            except (ValueError, KeyError, TypeError):
                pass
        if need is None:
            m = re.search(r"= (\d+) vCPU, plus .* quota \S+ \((\d+) vCPU\)", line)
            if m:
                need = (int(m.group(1)), int(m.group(2)))
        return r.returncode, line, need

    def orphans(self, context):
        self.n_checks += 1
        log = os.path.join(self.dir, "orphans-%02d.txt" % self.n_checks)
        with open(log, "w") as f:
            rc = subprocess.run(cmd("AK2_CAMPAIGN_ORPHANS", ["make", "orphans"]), stdout=f, stderr=subprocess.STDOUT,
                                cwd=ROOT).returncode
        if rc == 0:
            say("orphans (%s): none (%s)" % (context, rel(log)))
        elif self.inflight:
            say("orphans (%s): rc %d with %d campaign run(s) in flight: informational (%s)" % (context, rc, len(self.inflight), rel(log)))
        else:
            say("orphans (%s): rc %d with nothing in flight: HARD STOP (%s)" % (context, rc, rel(log)))
            self.halt("make orphans rc %d with nothing in flight (%s)" % (rc, rel(log)), hard=True)
        return rc

    def law1(self, context):
        """make g3-ladder into the campaign's tables dir. Judged only with its summary line; a
        Law 1 DEFECT, or no judgement, is a hard stop. Sets self.attr (in_attribution by run id)."""
        self.n_checks += 1
        log = os.path.join(self.dir, "g3-ladder-%02d.log" % self.n_checks)
        judged, hits, attr, rc = run_tables(self.tables, log)
        self.attr = attr
        if hits:
            say("g3-ladder (%s): Law 1 DEFECT: %s (%s)" % (context, hits[0], rel(log)))
            self.halt("Law 1 DEFECT from make g3-ladder (%s)" % rel(log), hard=True)
            return False
        if not judged:
            say("g3-ladder (%s): rc %d and no summary line: Law 1 not judged (%s)" % (context, rc, rel(log)))
            self.halt("make g3-ladder rc %d without its summary line: Law 1 not judged (%s)" % (rc, rel(log)), hard=True)
            return False
        say("g3-ladder (%s): no Law 1 DEFECT (rc %d; %s)" % (context, rc, rel(log)))
        return True

    # -- scheduling
    def family_load(self, fam):
        return sum(x["item"]["nodes"] for x in self.inflight if x["item"]["family"] == fam)

    def eligible(self, it):
        if it["rung"] in self.blocked:
            return "rung stopped"
        if len(self.inflight) >= self.conc:
            return "CONCURRENCY=%d runs in flight" % self.conc
        if self.inflight and not self.any_ok:
            return "the first launch runs alone until a run succeeds"
        if any(x["item"]["rung"] == it["rung"] for x in self.inflight):
            return "the rung's earlier rep is in flight"
        if any(q is not it and q["rung"] == it["rung"] and q["rep"] < it["rep"] for q in self.queue):
            return "the rung's earlier rep has not run"
        lim = self.limits.get(it["family"], DEFAULT_FAMILY_LIMIT)
        load = self.family_load(it["family"])
        if load and load + it["nodes"] > lim:
            return "family %s at its limit (%d of %d instances)" % (it["family"], load, lim)
        return None

    def drop_blocked(self):
        keep = []
        for q in self.queue:
            if q["rung"] in self.blocked:
                self.dropped.append((q, "not launched: rung %s stopped (%s)" % (q["rung"], self.blocked[q["rung"]])))
                self.row(q, None, None, None, "not-launched", "rung stopped: " + self.blocked[q["rung"]])
                say("not launched: %s rep %d (rung stopped: %s)" % (q["rung"], q["rep"], self.blocked[q["rung"]]))
            else:
                keep.append(q)
        self.queue = keep

    def pick(self):
        """The next item to launch, or None. A quota refusal (quota_check exit 1) is permanent when the
        item's own vCPUs exceed the quota with nothing else running: its rung stops at once, and the
        rest of its family is not held up. Any other refusal (instances already running) is waited
        for, the family asked again after the retry time, for at most AK2_CAMPAIGN_QUOTA_MAX_WAIT_S in
        total per item (default 6 h); after that the rung stops. The clock counts only the time
        between refusals at which none of the campaign's own runs of that family is in flight (a wait
        on its own sibling runs is the schedule, not the quota), to within the retry interval."""
        quota_wait, reasons = set(), []
        for it in self.queue:
            why = self.eligible(it)
            if why is None and (it["family"] in quota_wait or time.time() < self.quota_next.get(it["family"], 0)):
                why = "quota (waiting to check again)"
            if why is None:
                rc, line, need = self.quota(it)
                if rc == 0:
                    return it
                if rc == 1:
                    key = (it["rung"], it["rep"])
                    if need is not None and need[0] > need[1]:
                        self.blocked[it["rung"]] = ("quota: %d x %s = %d vCPU exceeds the %s on-demand quota of %d vCPU on its "
                                                    "own (permanent until the quota is raised)" % (it["nodes"], it["type"], need[0],
                                                                                                    it["family"], need[1]))
                        say("quota: %s rep %d stopped: %s" % (it["rung"], it["rep"], self.blocked[it["rung"]]))
                        continue
                    now = time.time()
                    acc, last = self.quota_waited.get(key, (0.0, None))
                    if last is not None and not self.family_load(it["family"]):
                        acc += now - last
                    self.quota_waited[key] = (acc, now)
                    if acc > self.quota_max_wait:
                        self.blocked[it["rung"]] = ("quota: refused for %.0f s (over the %.0f s bound; time waiting on the "
                                                    "campaign's own runs not counted) while other instances ran: %s"
                                                    % (acc, self.quota_max_wait, line))
                        say("quota: %s rep %d stopped: %s" % (it["rung"], it["rep"], self.blocked[it["rung"]]))
                        continue
                    quota_wait.add(it["family"])
                    self.quota_next[it["family"]] = time.time() + self.quota_retry
                    why = "quota_check: " + line
                else:
                    self.halt("quota_check could not judge %d x %s (rc %d): %s" % (it["nodes"], it["type"], rc, line), hard=True)
                    return None
            reasons.append("%s rep %d: %s" % (it["rung"], it["rep"], why))
        if any(q["rung"] in self.blocked for q in self.queue):
            self.drop_blocked()
        w = "; ".join(reasons[:3])
        if reasons and w != self.waiting:
            say("waiting: %s%s" % (w, "; ..." if len(reasons) > 3 else ""))
            self.waiting = w
        return None

    def launch(self, it):
        dirty = self.tree_dirty()
        if dirty:
            self.halt("the tree has changes under %s; run.sh would refuse: %s" % (" ".join(RUN_PATHS), dirty), hard=True)
            return
        self.queue.remove(it)
        tag = "%s-rep%d%s" % (it["rung"], it["rep"], "-" + it["az_override"] if it.get("az_override") else "")
        log = os.path.join(self.dir, tag + ".log")
        # The parent make's command-line variables (MAKEFLAGS) and DRY_RUN must not reach make run.
        env = {k: v for k, v in os.environ.items()
               if k not in ("DRY_RUN", "AK2_LAUNCH_AZ", "AK2_LAUNCH_AZ_REASON", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES")}
        env["AK2_LADDER_REP"] = str(it["rep"])
        if it.get("az_override"):
            env["AK2_LAUNCH_AZ"] = it["az_override"]
            env["AK2_LAUNCH_AZ_REASON"] = it["az_reason"]
        argv = cmd("AK2_CAMPAIGN_RUN", ["make", "run"]) + ["GATE=g3", "SPEC=" + it["spec"], "NODES=%d" % it["nodes"]]
        say("launch %s rep %d: %s (AK2_LADDER_REP=%d%s; %d x %s, family %s; driver log %s)" % (
            it["rung"], it["rep"], " ".join(argv), it["rep"],
            ", AK2_LAUNCH_AZ=" + it["az_override"] if it.get("az_override") else "", it["nodes"], it["type"],
            it["family"], rel(log)))
        # The driver writes to its log file, not to a pipe of ours, and runs in its own session: if
        # the campaign dies, the driver and its finish trap carry on and cohort.json is written.
        with open(log, "w") as f:
            p = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True)
        x = {"item": it, "proc": p, "log": log, "cohort_id": None, "settled": False, "t0": time.time()}
        x["tail"] = threading.Thread(target=self.tail, args=(x,), daemon=True)
        x["tail"].start()
        self.inflight.append(x)

    def tail(self, x):
        """Follow the driver's log file: stream it, prefixed, and pick out the cohort id."""
        pre = "  [%s r%d] " % (x["item"]["rung"], x["item"]["rep"])
        buf = ""
        with open(x["log"], errors="replace") as f:
            while True:
                chunk = f.read()
                if chunk:
                    buf += chunk
                    *lines, buf = buf.split("\n")
                    for line in lines:
                        print(pre + line, flush=True)
                        m = re.search(r"cohort (\d{8}-\d{6}-[0-9a-f]{7}-[0-9a-f]{4}-n\d+):", line)
                        if m and not x["cohort_id"]:
                            x["cohort_id"] = m.group(1)
                elif x["proc"].poll() is not None:
                    if buf:
                        print(pre + buf, flush=True)
                    return
                else:
                    time.sleep(0.2)

    def settled(self, x):
        """A launch has settled once its driver ended, or every member manifest records .launch
        (spawn task run returned), or the settle time ran out: only then can quota_check see it."""
        if x["settled"]:
            return True
        if x["proc"].poll() is not None:
            x["settled"] = True
        elif x["cohort_id"]:
            ms = [load_json(os.path.join(ROOT, "results", "g3", "%s-r%d" % (x["cohort_id"], k), "manifest.json"))
                  for k in range(x["item"]["nodes"])]
            if all(m and m.get("launch") for m in ms):
                x["settled"] = True
        if not x["settled"] and time.time() - x["t0"] > self.settle_s:
            say("%s rep %d: not settled after %d s; going on" % (x["item"]["rung"], x["item"]["rep"], self.settle_s))
            x["settled"] = True
        return x["settled"]

    # -- outcomes
    def classify(self, x, rc):
        """The outcome from the record (cohort.json, member manifests, ladder_tables' attribution),
        not from make run's exit: run-multi's exit can be non-zero for reasons that are not the run's."""
        it = x["item"]
        want_az = it.get("az_override") or it["az"]
        cid = x["cohort_id"]
        cdir = os.path.join(ROOT, "results", "g3", cid) if cid else None
        cj = load_json(os.path.join(cdir, "cohort.json")) if cdir else None
        texts = []
        for p in [x["log"]] + (glob.glob(os.path.join(cdir, "rank-*.run.log")) if cdir else []) + \
                (glob.glob(os.path.join(ROOT, "results", "g3", cid + "-r*", "launch.err")) if cid else []):
            try:
                with open(p, errors="replace") as f:
                    texts.append(f.read())
            except OSError:
                pass
        text = "\n".join(texts)
        cost = cj.get("cost_usd") if cj else None
        members = (cj or {}).get("members") or []
        run_dir = rel(cdir) if cdir else None
        if cj:
            why = record_problems(cdir, cj, member_manifests(cdir, cj), want_az)
            ia = self.attr.get(cid)
            if ia is None:
                why.append("not in ladder_tables' runs.tsv")
            elif ia != "yes":
                why.append("excluded by ladder_tables: %s" % ia[:160])
            if not why:
                return "ok", cost, run_dir, "clean record, in the attribution" + ("" if rc == 0 else "; make run rc %d (not the run's)" % rc)
        else:
            why = ["no cohort.json"]
        if "InsufficientInstanceCapacity" in text:
            return "capacity", cost, run_dir, "InsufficientInstanceCapacity"
        if "would exceed the region's on-demand vCPU quota" in text and not any(m.get("instance_id") for m in members):
            return "quota", cost, run_dir, "run-multi refused before launch: vCPU quota"
        return "fail", cost, run_dir, "make run rc %d; %s" % (rc, "; ".join(why))

    def finish(self, x, rc):
        it = x["item"]
        x["tail"].join(timeout=30)
        ctx = "after %s rep %d" % (it["rung"], it["rep"])
        self.orphans(ctx)
        self.law1(ctx)
        cls, cost, run_dir, note = self.classify(x, rc)
        az = it.get("az_override") or it["az"]
        self.outcomes.append((it, cls, run_dir, rc, cost))
        say("ended %s rep %d: class %s, make run rc %d, cost %s, run dir %s (%s)" % (it["rung"], it["rep"], cls, rc, cost, run_dir, note))
        if cls == "ok":
            self.any_ok = True
        elif cls == "capacity":
            ev = (run_dir + "/rank-0.run.log") if run_dir else rel(x["log"])
            d = (os.path.basename(run_dir) if run_dir else "-",
                 "capacity: InsufficientInstanceCapacity in %s (%s, %s c%d rep %d; make ladder-campaign %s)" % (
                     az, it["type"], it["rung"], self.cohort, it["rep"], self.ts),
                 "%s (results/g3/ladder-campaign/%s.tsv)" % (ev, self.ts))
            self.pending_defects.append(d)
            with open(self.defects_tsv, "a") as f:
                f.write("\t".join(d) + "\n")
            alt = None
            if not it["retried"]:
                for r in LL.az_rows():
                    if r.get("type") == it["type"] and r.get("az") not in it["tried_azs"]:
                        try:
                            LL.az_alt(r["type"], r["az"])
                            alt = r
                            break
                        except ValueError as e:
                            say("AZ list row skipped: %s" % e)
            if alt:
                self.queue.insert(0, dict(it, retried=True, az_override=alt["az"], tried_azs=it["tried_azs"] + [alt["az"]],
                                          az_reason="capacity retry after InsufficientInstanceCapacity in %s (%s)" % (az, run_dir or "-")))
                note += "; retry once in %s (scripts/g3/ladder.azs.tsv: %s)" % (alt["az"], alt["evidence"])
                say("%s rep %d: retry once in %s" % (it["rung"], it["rep"], alt["az"]))
            else:
                why = ("capacity again after the one retry" if it["retried"] else
                       "capacity in %s, and scripts/g3/ladder.azs.tsv documents no other AZ for %s" % (az, it["type"]))
                self.blocked[it["rung"]] = why
                note += "; " + why
        elif cls == "quota":
            n = it.get("quota_requeues", 0) + 1
            if n <= 3:
                self.queue.insert(0, dict(it, quota_requeues=n))
                note += "; requeued (%d of 3)" % n
            else:
                self.blocked[it["rung"]] = "refused for quota 4 times"
        else:
            self.blocked[it["rung"]] = "%s rep %d failed: %s (%s)" % (it["rung"], it["rep"], note, run_dir or rel(x["log"]))
            say("rung %s stopped: no further launches of it" % it["rung"])
        self.row(it, run_dir, rc, cost, cls, note)
        self.drop_blocked()

    def reap(self):
        for x in list(self.inflight):
            rc = x["proc"].poll()
            if rc is not None:
                self.inflight.remove(x)
                self.finish(x, rc)

    def interrupt(self, signum, _frame):
        self.halt("signal %d" % signum, hard=True)
        for x in self.inflight:
            try:
                os.killpg(x["proc"].pid, signal.SIGTERM)
            except OSError:
                pass

    def run(self):
        # INT and TERM stop launching and pass TERM to the drivers. HUP is left alone, so the
        # campaign can run under nohup (or tmux) and outlive the terminal.
        signal.signal(signal.SIGINT, self.interrupt)
        signal.signal(signal.SIGTERM, self.interrupt)
        for it in self.skipped:
            self.row(it, it["done_dir"], 0, None, "skip", it["why"])
        while self.queue or self.inflight:
            self.reap()
            if self.stop is None and self.queue and all(self.settled(x) for x in self.inflight):
                it = self.pick()
                if it is not None:
                    self.launch(it)
                    continue
            if self.stop is not None and not self.inflight:
                break
            time.sleep(self.poll)
        for q in self.queue:
            self.dropped.append((q, "not launched: " + (self.stop or "?")))
            self.row(q, None, None, None, "not-launched", self.stop or "?")
        self.queue = []
        self.orphans("end of the campaign, nothing in flight")
        if self.pending_defects:
            with open(DEFECTS, "a") as f:
                for d in self.pending_defects:
                    f.write("\t".join(d) + "\n")
            say("appended %d capacity row(s) to %s (uncommitted: the coordinator commits it)" % (len(self.pending_defects), rel(DEFECTS)))
        return self.summary()

    def summary(self):
        say("summary (results/g3/ladder-campaign/%s.tsv):" % self.ts)
        for it in self.skipped:
            say("  skip   %-11s rep %d: %s" % (it["rung"], it["rep"], it["why"]))
        for it, cls, run_dir, rc, cost in self.outcomes:
            say("  %-6s %-11s rep %d: %s rc %d cost %s" % (cls, it["rung"], it["rep"], run_dir, rc, cost))
        for it, why in self.dropped:
            say("  not    %-11s rep %d: %s" % (it["rung"], it["rep"], why))
        spent = sum(c for _, _, _, _, c in self.outcomes if isinstance(c, (int, float)))
        say("  spend this campaign: $%.2f; rungs stopped: %s" % (spent, "; ".join("%s (%s)" % kv for kv in self.blocked.items()) or "none"))
        if self.hard:
            say("exit 3: %s" % self.stop)
            return 3
        if self.blocked or self.dropped:
            say("exit 1: not every planned launch succeeded")
            return 1
        say("exit 0: every planned launch succeeded")
        return 0


def parse_limits(s):
    out = {}
    for kv in re.split(r"[,\s]+", s or ""):
        if not kv:
            continue
        m = re.fullmatch(r"([A-Za-z+]+)=([1-9][0-9]*)", kv)
        if not m:
            raise SystemExit("ladder-campaign: FAMILY_LIMITS entry %r (want e.g. X=2)" % kv)
        out[m.group(1)] = int(m.group(2))
    out.setdefault("X", 2)
    return out


def main(a):
    if len(a) < 2 or a[0] not in ("plan", "run") or not re.fullmatch(r"[1-9][0-9]*", a[1]):
        print(__doc__, file=sys.stderr)
        return 2
    mode, cohort = a[0], int(a[1])
    reps, rungs, limits, conc = 2, None, "", 1
    rest = a[2:]
    while rest:
        if len(rest) < 2:
            raise SystemExit("ladder-campaign: %s needs a value" % rest[0])
        f, v, rest = rest[0], rest[1], rest[2:]
        if f in ("--reps", "--concurrency"):
            if not re.fullmatch(r"[1-9][0-9]*", v):
                raise SystemExit("ladder-campaign: %s=%s" % (f[2:].upper(), v))
            if f == "--reps":
                reps = int(v)
            else:
                conc = int(v)
        elif f == "--rungs":
            rungs = [r for r in re.split(r"[,\s]+", v) if r] or None
        elif f == "--family-limits":
            limits = v
        else:
            raise SystemExit("ladder-campaign: unknown option %s" % f)
    limits = parse_limits(limits)
    ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    if mode == "plan":
        # ladder_tables' attribution, into a scratch dir outside the repo.
        tmp = tempfile.mkdtemp(prefix="ladder-campaign-plan.")
        try:
            judged, hits, attr, rc = run_tables(os.path.join(tmp, "tables"), os.path.join(tmp, "g3-ladder.log"))
            if not judged:
                say("refused: make g3-ladder rc %d without its summary line; the attribution is not known:\n%s" % (
                    rc, open(os.path.join(tmp, "g3-ladder.log"), errors="replace").read()[-2000:]))
                return 3
            items, record, notes = plan(cohort, reps, rungs, attr)
            print_plan(cohort, reps, items, record, notes, conc, limits)
            if hits:
                say("Law 1 DEFECT in the record (a real campaign refuses to start): %s" % hits[0])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        d = git("status", "--porcelain", "--", *RUN_PATHS).stdout.rstrip()
        say("tree: %s" % ("clean under " + " ".join(RUN_PATHS) if not d else "CHANGES under run.sh's paths (a real campaign refuses):\n" + d))
        say("DRY_RUN=1: nothing launched, nothing written in the repo")
        return 0
    # The real campaign: refuse to start on a dirty tree, orphans, or a Law 1 DEFECT already in the record.
    os.makedirs(CAMPAIGN_DIR, exist_ok=True)
    c = Campaign(cohort, reps, [], conc, limits, ts)
    say("campaign %s: log results/g3/ladder-campaign/%s.tsv, driver logs results/g3/ladder-campaign/%s/" % (ts, ts, ts))
    dirty = c.tree_dirty()
    if dirty:
        say("refused: the tree has changes under run.sh's paths; commit first:\n" + dirty)
        return 2
    c.orphans("before the first launch, nothing in flight")
    c.law1("before the first launch")
    if c.stop:
        say("refused to start: %s" % c.stop)
        return 3
    items, record, notes = plan(cohort, reps, rungs, c.attr)
    c.queue = [i for i in items if i["action"] == "launch"]
    c.skipped = [i for i in items if i["action"] == "skip"]
    lines = []
    print_plan(cohort, reps, items, record, notes, conc, limits, out=lambda l: (lines.append(l), print(l, flush=True)))
    with open(os.path.join(CAMPAIGN_DIR, ts + ".plan.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return c.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
