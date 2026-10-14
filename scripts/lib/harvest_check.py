#!/usr/bin/env python3
"""make harvest's verifier (docs/conductor.md, "Harvest"): a conductor's staged campaign, fetched into
STAGE (its conductor.json, changes.tsv, tracked.patch and tree/), checked against the repo at ROOT.

  harvest_check.py --stage DIR --campaign <conductor run id> [--root ROOT] [--partial]

Fails (exit 1, every reason printed) unless:
  - tracked.patch has the sha256 in tracked.patch.sha256 and touches only scripts/lib/g3_defects.tsv,
    and conductor.json lists no other tracked change (unexpected_tracked);
  - conductor.json names this campaign and says ended (--partial: a conductor still running is
    reported, not refused);
  - changes.tsv and tree/ agree: every listed file staged with its sha256 and size, nothing else;
  - no staged file would overwrite a different file in ROOT;
  - every staged run dir's manifest is finalised, finalised_by conductor with this campaign's run id,
    from the conductor's commit; its spec_sha256 is its spec.json's and the committed spec's (at that
    commit); its tables/util.json inputs have the sha256 they cite (staged, else ROOT, else at the commit);
  - every staged cohort.json records finalised_by conductor and its members are staged;
  - the campaign tsv (results/g3/ladder-campaign/<ts>.tsv) is staged when a campaign ran, every row
    names a run dir that exists (staged for launched rows, staged or in ROOT for skips) or none, and
    every staged cohort dir is in it.
stdout: one JSON summary (paths to add, spend, conductor state); stderr: the verdict, line by line.
"""
import argparse
import csv
import glob
import hashlib
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
CLASSES = {"ok", "skip", "fail", "capacity", "quota", "not-launched"}


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def git_blob_sha(root, commit, path):
    r = subprocess.run(["git", "-C", root, "show", "%s:%s" % (commit, path)], capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None


def main(a):
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True)
    ap.add_argument("--campaign", required=True)
    ap.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    ap.add_argument("--partial", action="store_true")
    o = ap.parse_args(a)
    S, R, cid = o.stage, o.root, o.campaign
    T = os.path.join(S, "tree")
    bad, notes = [], []
    cj = load(os.path.join(S, "conductor.json"))
    if cj is None:
        print("harvest: FAIL no conductor.json in the staging prefix", file=sys.stderr)
        return 1
    if cj.get("conductor_run_id") != cid:
        bad.append("conductor.json names %s, not %s" % (cj.get("conductor_run_id"), cid))
    if not cj.get("ended"):
        (notes if o.partial else bad).append("the conductor has not ended (state %r, updated %s)%s" % (
            cj.get("state"), cj.get("updated_at"), "" if o.partial else "; PARTIAL=1 harvests what is staged so far"))
    commit = cj.get("commit") or ""
    if cj.get("unexpected_tracked"):
        bad.append("the campaign changed tracked files other than scripts/lib/g3_defects.tsv: %s" % ", ".join(cj["unexpected_tracked"]))
    tp, ts_ = os.path.join(S, "tracked.patch"), os.path.join(S, "tracked.patch.sha256")
    if os.path.exists(tp):
        want = open(ts_).read().strip() if os.path.exists(ts_) else None
        if want != sha(tp):
            bad.append("tracked.patch sha256 %s, tracked.patch.sha256 says %s" % (sha(tp)[:12], (want or "nothing")[:12]))
        with open(tp, errors="replace") as f:
            touched = sorted({l.split(" b/", 1)[1].strip() for l in f if l.startswith("diff --git ")})
        if touched and touched != ["scripts/lib/g3_defects.tsv"]:
            bad.append("tracked.patch touches %s; only scripts/lib/g3_defects.tsv may change" % ", ".join(touched))
    # changes.tsv against tree/
    listed = {}
    cp = os.path.join(S, "changes.tsv")
    if os.path.exists(cp):
        with open(cp) as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) == 3:
                    listed[c[2]] = (c[0], int(c[1]))
    elif cj.get("state") not in ("drained-before-start",) and not str(cj.get("state", "")).startswith("failed"):
        bad.append("no changes.tsv")
    staged = set()
    for d, _, fs in os.walk(T):
        for f in fs:
            staged.add(os.path.relpath(os.path.join(d, f), T))
    for p in sorted(set(listed) - staged):
        bad.append("listed in changes.tsv but not staged: %s" % p)
    for p in sorted(staged - set(listed)):
        bad.append("staged but not in changes.tsv: %s" % p)
    for p in sorted(staged & set(listed)):
        s, n = listed[p]
        fp = os.path.join(T, p)
        if sha(fp) != s or os.path.getsize(fp) != n:
            bad.append("%s: sha256/size %s/%d, changes.tsv says %s/%d" % (p, sha(fp)[:12], os.path.getsize(fp), s[:12], n))
        tgt = os.path.join(R, p)
        if os.path.exists(tgt) and sha(tgt) != sha(fp):
            bad.append("%s exists in the repo with other content; not overwriting" % p)
    # run dirs and cohort dirs
    runs, cohorts, spend = [], [], 0.0
    for m in sorted(glob.glob(os.path.join(T, "results", "*", "*", "manifest.json"))):
        d = os.path.dirname(m)
        rd = os.path.relpath(d, T)
        man = load(m)
        if man is None:
            bad.append("%s: manifest.json does not parse" % rd)
            continue
        runs.append(rd)
        why = []
        if not man.get("manifest_finalised_at"):
            why.append("not finalised (scripts/refinalise.sh %s)" % rd)
        if man.get("finalised_by") != "conductor" or man.get("finalised_by_run_id") != cid:
            why.append("finalised_by %r run %r, not conductor %s" % (man.get("finalised_by"), man.get("finalised_by_run_id"), cid))
        if commit and man.get("commit") != commit:
            why.append("commit %s, not the conductor's %s" % (str(man.get("commit"))[:7], commit[:7]))
        ss, spec = man.get("spec_sha256"), man.get("spec")
        sj = os.path.join(d, "spec.json")
        if not os.path.exists(sj) or sha(sj) != ss:
            why.append("spec.json is not spec_sha256 %s" % str(ss)[:12])
        if spec and git_blob_sha(R, man.get("commit") or "HEAD", spec) != ss:
            why.append("spec_sha256 %s is not the committed %s at %s" % (str(ss)[:12], spec, str(man.get("commit"))[:7]))
        for uj in glob.glob(os.path.join(d, "tables", "util.json")):
            u = load(uj) or {}
            for inp in u.get("inputs", []):
                p = inp.get("path", "")
                cands = [os.path.join(T, p), os.path.join(R, p)]
                got = [sha(c) for c in cands if os.path.exists(c)]
                if inp.get("sha256") not in got and git_blob_sha(R, u.get("commit") or commit or "HEAD", p) != inp.get("sha256"):
                    why.append("tables/util.json cites %s sha256 %s, which no copy has" % (p, str(inp.get("sha256"))[:12]))
        for w in why:
            bad.append("%s: %s" % (rd, w))
    for c in sorted(glob.glob(os.path.join(T, "results", "*", "*", "cohort.json"))):
        d = os.path.dirname(c)
        rd = os.path.relpath(d, T)
        cjj = load(c) or {}
        cohorts.append(rd)
        if cjj.get("finalised_by") != "conductor" or cjj.get("finalised_by_run_id") != cid:
            bad.append("%s: cohort.json finalised_by %r, not conductor %s" % (rd, cjj.get("finalised_by"), cid))
        for k in range(cjj.get("nodes") or 0):
            if not os.path.exists(os.path.join(T, "%s-r%d" % (rd, k), "manifest.json")):
                bad.append("%s: member r%d not staged" % (rd, k))
        if isinstance(cjj.get("cost_usd"), (int, float)):
            spend += cjj["cost_usd"]
    # the campaign tsv
    ts = cj.get("campaign_ts")
    tsvp = os.path.join(T, "results", "g3", "ladder-campaign", "%s.tsv" % ts) if ts else None
    in_tsv = set()
    if ts and not os.path.exists(tsvp):
        bad.append("the campaign %s ran but its tsv is not staged" % ts)
    elif tsvp:
        with open(tsvp) as f:
            for i, r in enumerate(csv.DictReader(f, delimiter="\t")):
                if r.get("class") not in CLASSES:
                    bad.append("%s row %d: class %r" % (os.path.basename(tsvp), i + 2, r.get("class")))
                rd = r.get("run_dir") or "-"
                if rd == "-":
                    if r.get("class") not in ("not-launched", "quota", "capacity"):
                        bad.append("%s row %d: class %s with no run dir" % (os.path.basename(tsvp), i + 2, r.get("class")))
                    continue
                in_tsv.add(rd)
                here = os.path.isdir(os.path.join(T, rd))
                if r.get("class") == "skip":
                    if not (here or os.path.isdir(os.path.join(R, rd))):
                        bad.append("%s row %d: skip names %s, which is nowhere" % (os.path.basename(tsvp), i + 2, rd))
                elif not here:
                    bad.append("%s row %d: %s not staged" % (os.path.basename(tsvp), i + 2, rd))
        for c in cohorts:
            if c not in in_tsv:
                bad.append("%s is staged but not in the campaign tsv" % c)
    elif cohorts:
        bad.append("cohort dirs staged without a campaign: %s" % ", ".join(cohorts))
    # what to add: each staged path's highest ancestor that is not in the repo yet (as git status
    # shows a new directory), else the file itself
    units = set()
    for p in staged:
        parts = p.split("/")
        u = p
        for i in range(1, len(parts)):
            if not os.path.exists(os.path.join(R, *parts[:i])):
                u = "/".join(parts[:i])
                break
        units.add(u)
    own = os.path.join(R, "results", "conductor", cid, "manifest.json")
    om = load(own)
    summary = {"campaign": cid, "conductor": cj, "ok": not bad, "problems": bad, "notes": notes, "runs": runs,
               "cohorts": cohorts, "add": sorted(units), "spend_usd": round(spend, 6),
               "conductor_run_dir": os.path.relpath(os.path.dirname(own), R) if om else None,
               "conductor_cost_usd": (om or {}).get("cost_usd"),
               "conductor_finalised": bool((om or {}).get("manifest_finalised_at"))}
    for n in notes:
        print("harvest: note %s" % n, file=sys.stderr)
    for b in bad:
        print("harvest: FAIL %s" % b, file=sys.stderr)
    print("harvest: %s: %d staged file(s), %d run dir(s), %d cohort(s), campaign %s, spend $%.2f" % (
        "verified" if not bad else "REFUSED", len(staged), len(runs), len(cohorts), ts or "none (plan only or not started)", spend),
        file=sys.stderr)
    print(json.dumps(summary))
    return 0 if not bad else 1



if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
