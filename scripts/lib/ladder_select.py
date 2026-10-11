#!/usr/bin/env python3
"""make ladder-select COHORT=<c> [RUNG=<rung>[,<rung>...]] [DRY_RUN=1] (docs/ladder.md, "Selection").

Applies each registered `select` rule of scripts/g3/ladder.levers.tsv at one cohort, from the
per-rung medians of a fresh run of make g3-ladder's program (scripts/lib/ladder_tables.py, into a
scratch dir), and writes the winners as rows of scripts/g3/ladder.resolved.tsv.

  ladder_select.py select COHORT [--rung R[,R...]] [--dry-run] [--root DIR]

The rules are read from the table, not restated here: a rule's candidates, axis (`median wall_s`
or `median billed_usd`) and ties (`fewer ...`) are parsed from its text, and a rule this program
cannot parse is refused. What it can select from the record:
  - an alias rung (Sstar-time, Sstar-cost): its candidates are its alias_of rungs, which must be the
    rule's own candidate list. Each needs n >= 2 measured runs at the cohort on the rule's axis;
    otherwise it is refused. The lowest median wins. An exact tie on the median is broken by the
    rule's ties (fewer vCPUs: the candidate's host); a tie left after that is refused.
  - The winner's margin over the runner-up is judged by the tables' own resolution rule
    (ladder_tables.delta: resolved only if |margin| > 2 x max(range, range, q)). A winner chosen from
    an unresolvable margin is still the rule's winner, and the row's `margin` column and note say so.
Every other rule is reported with what it still needs, and nothing is written for it:
  - a rung not run at this cohort (status not-run, or not_run_cohorts): its tokens resolve to its
    predecessor's values already;
  - a rung whose candidates are configurations (S4, S8, O2, O4b and their -cost copies): the record
    has no runs of a candidate that is not a rung of its own;
  - a rung chosen by the #26 fit (O3, O3-cost): not a ladder median.

A row: origin, cohort, key (alias), value (the winner), source (the tables' manifest.json in the
selection's snapshot dir under results/g3/ladder-select/), cites (path=sha256 of that manifest and
the snapshot's rungs.tsv and runs.tsv, and of every candidate run's cohort.json and member
manifests, or manifest.json), margin (resolved, or unresolvable: <reason>) and note (the rule's
sha256, every candidate's median, n, range, q and host, the margin and its threshold, and the
net-series order beside it). scripts/lib/ladder_levers.py checks the source and every cite.

Deterministic and idempotent: a row whose winner, margin, note and cited runs are what this run
derives, and whose cites still hash, is left as it is, byte for byte, and no snapshot is written.
Only changed rows are written, with one snapshot dir named by the hash of their decisions.

Refuses (exit 3, nothing written): a table that fails make ladder-check; a g3-ladder run without
its summary line, or with a Law 1 DEFECT; a requested rung it cannot select. Exit 0 otherwise
(a run without --rung reports the rules it cannot select yet and writes the others). Exit 2: usage.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ladder_levers as LL  # noqa: E402
import ladder_tables as LT  # noqa: E402

COLS = ["origin", "cohort", "key", "value", "source", "cites", "margin", "note"]
HEADER = """# The resolutions of the ladder's placeholders, per cohort (docs/ladder.md, "Selection"; #51).
# Written by make ladder-select (scripts/lib/ladder_select.py); read by scripts/lib/ladder_levers.py
# (the generator: it checks the source and every cite) and by scripts/lib/ladder_tables.py (key alias).
# Columns: origin (the rung making the selection); cohort; key (alias, or a PARAM); value (the winner);
# source (a results/ file inside a run or snapshot dir); cites (path=sha256 ...: every file the
# selection used); margin (the winner's margin over the runner-up under the tables' resolution rule:
# resolved, or unresolvable: <reason>; an unresolvable winner is still the registered rule's winner);
# note (the rule's sha256, each candidate's median, n, range, q and host, the margin and threshold).
"""
NET = {"wall_s": "wall_net_s", "billed_usd": "billed_net_usd"}
SUMMARY = re.compile(r"^ladder_tables: \d+ ladder run\(s\), .* DEFECT\(s\) -> ", re.M)


class Refused(Exception):
    pass


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def parse_rule(text):
    """{'candidates', 'axis' (wall_s, billed_usd, or fit:<objective>), 'ties'} from a select rule's
    text; raises Refused if it names no candidates, axis or ties this program reads."""
    m = re.match(r"candidates: (.*?); (?=axis: |the #26 fit)", text)
    if not m:
        raise Refused("rule %r: no 'candidates: ...;' followed by an axis" % text)
    out = {"candidates": m.group(1)}
    a = re.search(r"(?:^|; )axis: median (wall_s|billed_usd)\b", text)
    f = re.search(r"(?:^|; )the #26 fit's (time|cost)-optimal N", text)
    if bool(a) == bool(f):
        raise Refused("rule %r: want exactly one axis (axis: median wall_s|billed_usd, or the #26 fit's time|cost-optimal N)" % text)
    out["axis"] = a.group(1) if a else "fit:" + f.group(1)
    t = re.search(r"(?:^|; )ties: fewer ([A-Za-z ]+?)(?:;|$)", text)
    if not t:
        raise Refused("rule %r: no 'ties: fewer ...'" % text)
    out["ties"] = t.group(1).strip()
    return out


def run_tables(root, cohort, scratch):
    """Run make g3-ladder's program on ROOT's record into SCRATCH. Refused without its summary line
    or with a Law 1 DEFECT (as make ladder-campaign judges it)."""
    lev = os.path.join(root, "scripts", "g3", "ladder.levers.tsv")
    res = os.path.join(root, "scripts", "g3", "ladder.resolved.tsv")
    p = subprocess.run([sys.executable, os.path.join(HERE, "ladder_tables.py"), "--results", os.path.join(root, "results"),
                        "--levers", lev, "--resolved", res, "--out", scratch], capture_output=True, text=True)
    log = p.stdout + p.stderr
    if not SUMMARY.search(p.stdout):
        raise Refused("g3-ladder gave no summary line (exit %d): Law 1 was not judged\n%s" % (p.returncode, log[-2000:]))
    if "DEFECT (Law 1)" in log:
        raise Refused("g3-ladder reports a Law 1 DEFECT; nothing is selected from that record\n%s" % log[-2000:])
    return [ln for ln in p.stdout.splitlines() if SUMMARY.match(ln)][-1]


def read_tables(d):
    def tsv(n):
        with open(os.path.join(d, n)) as f:
            return list(csv.DictReader(f, delimiter="\t"))
    with open(os.path.join(d, "manifest.json")) as f:
        man = json.load(f)
    return tsv("rungs.tsv"), tsv("runs.tsv"), man


def stats_of(rungs, rung, cohort, axis):
    for r in rungs:
        if r["rung"] == rung and r["cohort"] == str(cohort) and r["axis"] == axis:
            f = lambda k: LT.num(r[k])   # noqa: E731  (a number, or None for '', 'n<2', ...)
            return {"n": int(r["n"] or 0), "median": f("median"), "range": f("range"), "q": f("granularity_q"),
                    "basis": r["basis"]}
    return {"n": 0, "median": None, "range": None, "q": None, "basis": "measured"}


def run_files(root, run_dir):
    """The files that record a run: a cohort's cohort.json and its members' manifest.json, or a
    single run's manifest.json (repo-relative paths)."""
    full = os.path.join(root, run_dir)
    if os.path.isfile(os.path.join(full, "cohort.json")):
        with open(os.path.join(full, "cohort.json")) as f:
            c = json.load(f)
        out = [os.path.join(run_dir, "cohort.json")]
        for m in c.get("members") or []:
            out.append(os.path.join(os.path.dirname(run_dir), m["run_id"], "manifest.json"))
        return out
    return [os.path.join(run_dir, "manifest.json")]


def fmt(v):
    return "-" if v is None else "%.6f" % v


def select_alias(rows, row, cohort, rungs, runs, man, root):
    """The decision of an alias rung's rule at COHORT, or Refused."""
    names = LL.by_name(rows)
    rule = parse_rule(row["select"])
    cands = [c for c in row["alias_of"].split("|") if c]
    listed = [c.strip() for c in rule["candidates"].split(",")]
    if listed != cands:
        raise Refused("%s: the rule's candidates (%s) are not its alias_of (%s)" % (row["rung"], ", ".join(listed), ", ".join(cands)))
    axis = rule["axis"]
    if axis.startswith("fit:"):
        raise Refused("%s: an alias selected by the #26 fit is not read here" % row["rung"])
    if rule["ties"] != "vCPUs":
        raise Refused("%s: ties 'fewer %s' (this program breaks alias ties by fewer vCPUs only)" % (row["rung"], rule["ties"]))
    order = [r["rung"] for r in rows]
    st, short = {}, []
    for c in cands:
        s = stats_of(rungs, c, cohort, axis)
        if s["basis"] != "measured":
            short.append("%s is %s on %s" % (c, s["basis"], axis))
        elif s["n"] < 2 or s["median"] is None:
            short.append("%s has n = %d" % (c, s["n"]))
        host = LL.instance_of(rows, names[c])
        s.update(host=host, vcpus=LL.vcpus_of(host), net=stats_of(rungs, c, cohort, NET[axis]))
        if s["vcpus"] is None:
            short.append("%s: no vCPU count for its host %s (the tie-break)" % (c, host))
        st[c] = s
    if short:
        raise Refused("%s at c%d: %s; the rule needs every candidate at n >= 2" % (row["rung"], cohort, "; ".join(short)))
    rank = sorted(cands, key=lambda c: (st[c]["median"], st[c]["vcpus"], order.index(c)))
    w, ru = rank[0], rank[1]
    tie = ""
    if st[w]["median"] == st[ru]["median"]:
        if st[w]["vcpus"] == st[ru]["vcpus"]:
            raise Refused("%s at c%d: %s and %s tie on median %s and on vCPUs; the rule does not break it"
                          % (row["rung"], cohort, w, ru, axis))
        tie = "; the medians tie, broken by fewer vCPUs (%d < %d)" % (st[w]["vcpus"], st[ru]["vcpus"])
    d = LT.delta(st[ru], st[w])
    margin = d["status"]
    if margin != "resolved":
        margin += ": chosen by the registered rule from an unresolvable difference"
    nrank = sorted(cands, key=lambda c: (st[c]["net"]["median"] if st[c]["net"]["median"] is not None else float("inf"),
                                         st[c]["vcpus"], order.index(c)))
    nd = LT.delta(st[nrank[1]]["net"], st[nrank[0]]["net"])
    rsha = hashlib.sha256(row["select"].encode()).hexdigest()
    note = ("rule sha256 %s: lowest median %s of %s, ties fewer vCPUs; %s; winner %s, runner-up %s, margin %s, "
            "threshold %s (2 x max(spread %s, q %s))%s; net series %s (informational): lowest %s, margin over %s %s, %s"
            % (rsha, axis, ", ".join(cands),
               "; ".join("%s %s (n %d, range %s, q %s, %s %d vCPUs)" % (c, fmt(st[c]["median"]), st[c]["n"], fmt(st[c]["range"]),
                                                                        fmt(st[c]["q"]), st[c]["host"], st[c]["vcpus"]) for c in cands),
               w, ru, fmt(d["delta"]), fmt(d["threshold"]), fmt(d["measured_spread"]), fmt(d["q"]), tie,
               NET[axis], nrank[0], nrank[1], fmt(nd["delta"]), nd["status"] or "-"))
    # The runs behind each median: in the attribution, cold ladder runs of the candidate at this cohort.
    dirs = {r["run_id"]: r["dir"] for r in man.get("runs", [])}
    cites = []
    for c in cands:
        ids = sorted(r["run_id"] for r in runs if r["rung"] == c and r["cohort"] == str(cohort) and r["in_attribution"] == "yes"
                     and r.get("run_kind", "ladder") == "ladder" and r.get("state", "cold") == "cold")
        if len(ids) != st[c]["n"]:
            raise Refused("%s at c%d: %s has %d run(s) in the attribution but n = %d on %s" % (row["rung"], cohort, c, len(ids), st[c]["n"], axis))
        for i in ids:
            rd = dirs.get(i, os.path.join("results", "g3", i))
            rd = os.path.relpath(rd, root) if os.path.isabs(rd) else rd
            for p in run_files(root, rd):
                if not os.path.isfile(os.path.join(root, p)):
                    raise Refused("%s: %s (run %s) does not exist" % (row["rung"], p, i))
                cites.append("%s=%s" % (p, sha(os.path.join(root, p))))
    return {"origin": row["rung"], "cohort": str(cohort), "key": "alias", "value": w, "margin": margin, "note": note,
            "run_cites": cites, "winner": w, "runner_up": ru, "axis": axis, "delta": d, "stats": st}


def pending(rows, row, cohort, res):
    """Why a non-alias rule cannot be selected from the record at COHORT (one sentence)."""
    names = LL.by_name(rows)
    rung = row["rung"]
    why = LL.not_run_at(row, cohort)
    if why:
        return "not-run", "%s: its tokens already resolve to its run predecessor's values; no row is written" % why
    rule = parse_rule(row["select"])
    if rule["axis"].startswith("fit:"):
        return "pending", ("chosen by the #26 fit's %s-optimal N (results/g3/fit26/), not by a ladder median; it needs %s's type "
                           "resolved first, and a registered reading of the fit (which fit, and N restricted to the rule's set)"
                           % (rule["axis"][4:], row["predecessor"]))
    base = rung[:-5] if rung.endswith("-cost") else rung
    if base == "O4b":
        # INFLIGHT 1..vCPUs/THREADS on O3's type: with THREADS = vcpus there is one candidate, 1.
        try:
            t = LL._values(rows, row, cohort, res)[0].get("THREADS")
        except ValueError:
            t = None
        p = LL.run_pred_at(rows, row, cohort)
        pv = LL._values(rows, p, cohort, res)[0] if p is not None else {}
        if t == "vcpus" and pv.get("INFLIGHT") == "1":
            return "pending", ("its only candidate at c%d is INFLIGHT = 1 (THREADS = vcpus, so vCPUs / THREADS = 1), %s's own "
                               "configuration: like S4 and S8 at c1, it is a not_run_cohorts entry (a lever-table change), not a selection"
                               % (cohort, p["rung"]))
    what = {"S4": "P x T", "S8": "K replicas", "O2": "instance type", "O4b": "INFLIGHT"}.get(base, "configuration")
    return "pending", ("its candidates are %s values, and the record has runs only of rungs: a candidate that is not a rung of its "
                       "own cannot be measured (docs/ladder.md, \"Selection\": candidate rungs under an alias)" % what)


def load_existing(path):
    if not os.path.exists(path):
        return []
    return [dict((k, r.get(k, "")) for k in COLS) for r in LL.resolved_rows(path)]


def split_cites(cites, snap_prefix="results/g3/ladder-select/"):
    return [c for c in cites.split() if not c.startswith(snap_prefix)]


def write_file(path, rows, order):
    def key(r):
        c = r["cohort"].lstrip("c")
        return (order.index(r["origin"]) if r["origin"] in order else len(order), r["origin"], int(c) if c.isdigit() else 0, r["key"])
    with open(path + ".tmp", "w") as f:
        f.write(HEADER)
        f.write("\t".join(COLS) + "\n")
        for r in sorted(rows, key=key):
            if any("\t" in r[k] or "\n" in r[k] for k in COLS):
                raise Refused("a row of %s/%s holds a tab or newline" % (r["origin"], r["cohort"]))
            f.write("\t".join(r[k] for k in COLS) + "\n")
    os.replace(path + ".tmp", path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["select"])
    ap.add_argument("cohort")
    ap.add_argument("--rung", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--root", default=LL.ROOT)
    a = ap.parse_args(argv)
    if not re.fullmatch(r"[1-9][0-9]*", a.cohort):
        print("ladder-select: COHORT %r is not an integer >= 1" % a.cohort, file=sys.stderr)
        return 2
    cohort, root = int(a.cohort), os.path.abspath(a.root)
    lev = os.path.join(root, "scripts", "g3", "ladder.levers.tsv")
    resp = os.path.join(root, "scripts", "g3", "ladder.resolved.tsv")
    try:
        rows = LL.load(lev)
        probs = LL.check(rows)
        if probs:
            raise Refused("the lever table fails make ladder-check:\n  " + "\n  ".join(probs))
        names = LL.by_name(rows)
        order = [r["rung"] for r in rows]
        sel = [r for r in rows if r["select"]]
        want = [x for x in a.rung.split(",") if x]
        for x in want:
            if x not in names or not names[x]["select"]:
                raise Refused("%s is not a rung with a select rule (%s)" % (x, ", ".join(r["rung"] for r in sel)))
        if want:
            sel = [r for r in sel if r["rung"] in want]
        existing = load_existing(resp)
        try:
            res = LL.read_resolved(resp, root)
        except ValueError as e:
            raise Refused("the current ladder.resolved.tsv fails its citation check: %s" % e)
        scratch = tempfile.mkdtemp(prefix="ak2-ladder-select-")
        try:
            summ = run_tables(root, cohort, os.path.join(scratch, "tables"))
            print("ladder-select: fresh tables: %s" % summ.split(" -> ")[0])
            rungs, runs, man = read_tables(os.path.join(scratch, "tables"))
            decided, refused, other = [], [], []
            for r in sel:
                try:
                    if r["status"].startswith("alias:"):
                        decided.append(select_alias(rows, r, cohort, rungs, runs, man, root))
                    else:
                        other.append((r["rung"],) + pending(rows, r, cohort, res))
                except Refused as e:
                    refused.append((r["rung"], str(e)))
            for rung, kind, why in other:
                print("ladder-select: %s at c%d: %s: %s" % (rung, cohort, kind, why))
                if kind == "pending" and want:
                    refused.append((rung, "not selectable from the record: " + why))
            for d in decided:
                print("ladder-select: %s at c%d: %s by median %s, over %s by %s (threshold %s): %s"
                      % (d["origin"], cohort, d["winner"], d["axis"], d["runner_up"], fmt(d["delta"]["delta"]),
                         fmt(d["delta"]["threshold"]), d["margin"]))
            if refused:
                for rung, why in refused:
                    print("ladder-select: refused: %s at c%d: %s" % (rung, cohort, why), file=sys.stderr)
                raise Refused("%d rule(s) refused; nothing is written" % len(refused))
            # Unchanged rows stay byte for byte; changed ones are written with one snapshot.
            byk = {(r["origin"], r["cohort"].lstrip("c"), r["key"]): r for r in existing}
            change = []
            for d in decided:
                old = byk.get((d["origin"], d["cohort"], d["key"]))
                same = (old is not None and old["value"] == d["value"] and old["margin"] == d["margin"] and old["note"] == d["note"]
                        and split_cites(old["cites"]) == d["run_cites"] and not LL.cites_ok(old["cites"], root)
                        and not LL.source_ok(old["source"], root))
                print("ladder-select: %s at c%d: %s" % (d["origin"], cohort, "unchanged (the row stands)" if same else
                                                         ("new row" if old is None else "row replaced")))
                if not same:
                    change.append(d)
            if not change:
                print("ladder-select: nothing to write: scripts/g3/ladder.resolved.tsv is current for these rules")
                return 0
            fp = hashlib.sha256(json.dumps([[d[k] for k in ("origin", "cohort", "value", "margin", "note", "run_cites")] for d in change],
                                           sort_keys=True).encode()).hexdigest()[:12]
            snap = os.path.join("results", "g3", "ladder-select", "c%d-%s" % (cohort, fp))
            if a.dry_run:
                print("ladder-select: DRY_RUN: would write %s and %d row(s); nothing written" % (snap, len(change)))
                for d in change:
                    print("  %s\t%s\talias\t%s\tmargin: %s" % (d["origin"], d["cohort"], d["value"], d["margin"]))
                return 0
            full = os.path.join(root, snap)
            if not os.path.isdir(full):
                os.makedirs(os.path.dirname(full), exist_ok=True)
                shutil.copytree(os.path.join(scratch, "tables"), full)
            src = os.path.join(snap, "manifest.json")
            snapc = ["%s=%s" % (os.path.join(snap, n), sha(os.path.join(full, n))) for n in ("manifest.json", "rungs.tsv", "runs.tsv")]
            new = [r for r in existing if (r["origin"], r["cohort"].lstrip("c"), r["key"]) not in
                   {(d["origin"], d["cohort"], d["key"]) for d in change}]
            for d in change:
                new.append({"origin": d["origin"], "cohort": d["cohort"], "key": d["key"], "value": d["value"], "source": src,
                            "cites": " ".join(snapc + d["run_cites"]), "margin": d["margin"], "note": d["note"]})
            before = open(resp).read() if os.path.exists(resp) else None
            write_file(resp, new, order)
            # The written file must pass the generator's check and the tables' reading.
            try:
                LL.read_resolved(resp, root)
                _, errs = LT.load_resolved(resp, LT.Reader(), LT.load_levers(lev, LT.Reader()))
                if errs:
                    raise ValueError("; ".join(errs))
            except ValueError as e:
                if before is None:
                    os.unlink(resp)
                else:
                    with open(resp, "w") as f:
                        f.write(before)
                raise Refused("the written file failed its own check, restored: %s" % e)
            print("ladder-select: wrote %d row(s) to scripts/g3/ladder.resolved.tsv, citing %s/" % (len(change), snap))
            print("ladder-select: scripts/g3/ladder.resolved.tsv and %s/ are uncommitted: the coordinator must commit them "
                  "before the next launch (run.sh refuses a dirty tree)" % snap)
            return 0
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    except Refused as e:
        print("ladder-select: refused: %s" % e, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
