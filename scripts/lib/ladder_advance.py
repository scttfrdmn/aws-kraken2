#!/usr/bin/env python3
"""make ladder-advance COHORT=<c> [DRY_RUN=1] (docs/ladder.md, "Advancing a cohort").

  ladder_advance.py advance COHORT [--dry-run] [--no-select] [--root DIR]
  ladder_advance.py plan COHORT                       the stage plan only (no select, no generation)

Above c1 the ladder's selections are not forced, so a cohort's specs come in stages: a rung can be
generated only once every selection upstream of it is made, and a selection only once its
candidates have run. One invocation:
  1. runs make ladder-select COHORT=<c> (DRY_RUN passed on): the selections the record now allows
     are written to scripts/g3/ladder.resolved.tsv;
  2. resolves every run rung at the cohort (ladder_levers.resolve) and generates, with
     scripts/g3/mkspec-ladder.sh, every spec that is now fully determined and not committed (not under
     DRY_RUN); it repeats this until a pass generates nothing new;
  3. runs the static checks: make ladder-check, ladder_body_compat.py check and fresh;
  4. prints, for each stage, its rungs with their state and why, the selections still pending and
     what each waits on, and the summed cost_limit (an upper bound: for a rung not yet determined,
     the largest over every combination of the pending selections it depends on), and writes the
     plan table results/g3/ladder-advance/c<c>.plan.tsv (not under DRY_RUN);
  5. stops with what the coordinator must do: commit the new specs (and any new resolved rows),
     rehearse one spec per (classifier, upload, fleet shape) class, make dryrun-userdata, make
     ladder-campaign COHORT=<c>, and then make ladder-advance COHORT=<c> again.
It never launches, commits or pushes. Exit 0; 1 if a generation failed; 3 if ladder-select or a
static check refused; 2 usage.

States of a run rung at the cohort: committed (its spec is in git), new (generated now, or under
DRY_RUN would be), pending (waits on a selection), not-run (not_run_cohorts or status), alias (an
alias_cohorts entry holds: it reads another rung's runs), out (outside its alias's bracket or range),
collapsed (resolves identical to its predecessor: a selection made it a no-op, and the table needs a
not_run_cohorts entry for that cohort, a decision), blocked (any other refusal, e.g. a TTL above
AK2_MAX_TTL_S).

Stages (static): a rung with no pending selection upstream is stage 1; otherwise it is one more
than the latest stage among the candidates of the selections it depends on.
"""
import argparse
import collections
import csv
import itertools
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ladder_levers as LL  # noqa: E402
import ladder_ttl as TT  # noqa: E402

TOKEN = re.compile(r"@(?:select|floor):([A-Za-z0-9-]+)")
PLAN_COLS = ["cohort", "stage", "rung", "arm", "state", "spec", "type", "nodes", "ttl_min", "cost_limit_usd", "cost_limit_total_usd",
             "est_s", "basis", "bound", "waits_on", "note"]
COMBO_CAP = 20000


def spec_rel(rung, cohort):
    return "runs/g3-l-%s-c%d.json" % (rung.lower(), cohort)


def is_selection(row):
    return bool(row["select"])


def classify(msg):
    """(state, waits) of a resolve() refusal."""
    waits = sorted(set(TOKEN.findall(msg)))
    if "no spec is generated for it" in msg and ("not-run" in msg):
        return "not-run", []
    if "is alias: same configuration as" in msg:
        return "alias", []
    if "is outside" in msg and ("bracket" in msg or "range" in msg) and "not a candidate there" in msg:
        return "out", []
    if "identical to" in msg and "mark it not-run instead" in msg:
        return "collapsed", []
    if waits and ("unresolved" in msg or "undecided" in msg):
        return "pending", waits
    return "blocked", waits


# ---------------------------------------------------------------- static stages

def _origin_deps(rows, o, cohort, seen):
    """The selections a token @select:O / @floor:O depends on at COHORT."""
    names = LL.by_name(rows)
    r = names.get(o)
    if r is None or o in seen:
        return set()
    seen = seen | {o}
    if LL.not_run_at(r, cohort):
        p = LL.run_pred_at(rows, r, cohort)
        return row_deps(rows, p, cohort, seen) if p is not None else set()
    out = set()
    t, cond = LL.alias_decl(r, cohort)
    if t and t in names:
        out |= row_deps(rows, names[t], cohort, seen)
        if not cond:
            return out
    if is_selection(r) or r["status"].startswith("alias:"):
        return out | {o}
    return out | row_deps(rows, r, cohort, seen)


def row_deps(rows, row, cohort, seen=frozenset()):
    """The selections (alias or selecting rungs, run at COHORT) ROW's values depend on."""
    out = set()
    vals = [row[k] for k in LL.KEYS] + [LL.instance_of(rows, row)]
    for v in vals:
        for o in TOKEN.findall(v):
            if o == row["rung"]:
                continue
            out |= _origin_deps(rows, o, cohort, seen | {row["rung"]})
    t, cond = LL.alias_decl(row, cohort)
    if t and cond:
        names = LL.by_name(rows)
        if t in names:
            out |= row_deps(rows, names[t], cohort, seen | {row["rung"]})
    return out


def applicable(rows, sel, cohort):
    """The candidates of selection SEL that apply at COHORT statically (its predecessor always)."""
    names = LL.by_name(rows)
    return [c for c in sel["alias_of"].split("|") if c and (c == sel["predecessor"] or not LL.not_run_at(names[c], cohort))]


def stages(rows, cohort):
    """rung -> stage for every rung (run rungs and selections) at COHORT."""
    names = LL.by_name(rows)
    memo, sel_memo = {}, {}

    def sel_stage(s, path):
        if s in sel_memo:
            return sel_memo[s]
        row = names[s]
        st = 0
        for c in applicable(rows, row, cohort):
            cr = names[c]
            if c in path:
                continue
            if cr["status"].startswith("alias:"):
                st = max(st, sel_stage(c, path | {c}))
            elif not LL.not_run_at(cr, cohort):
                st = max(st, stage(c, path | {c}))
            else:
                p = LL.run_pred_at(rows, cr, cohort)
                if p is not None:
                    st = max(st, stage(p["rung"], path | {p["rung"]}))
        sel_memo[s] = st
        return st

    def stage(r, path=frozenset()):
        if r in memo:
            return memo[r]
        d = row_deps(rows, names[r], cohort)
        st = 1 + max([sel_stage(s, path | {r}) for s in d] or [0])
        memo[r] = st
        return st

    out = {}
    for r in rows:
        out[r["rung"]] = sel_stage(r["rung"], frozenset([r["rung"]])) if r["status"].startswith("alias:") else stage(r["rung"])
    return out


def closure(rows, deps, cohort):
    """Every selection that decides DEPS' values: DEPS and, in turn, those of their candidates."""
    names = LL.by_name(rows)
    out, todo = set(), list(deps)
    while todo:
        s = todo.pop()
        if s in out:
            continue
        out.add(s)
        for c in applicable(rows, names[s], cohort):
            if names[c]["status"].startswith("alias:"):
                todo.append(c)
            todo += list(row_deps(rows, names[c], cohort) - out)
    return out


# ---------------------------------------------------------------- prices and costs

class Prices:
    """On-demand $/h per type: scripts/g3/ladder.types.tsv, then AK2_ADVANCE_PRICES (type=price,...: the
    test's seam), then truffle (as mkspec-ladder.sh asks it)."""

    def __init__(self, root):
        self.p = {}
        tp = os.path.join(root, "scripts", "g3", "ladder.types.tsv")
        if os.path.exists(tp):
            with open(tp) as f:
                for d in csv.DictReader([l for l in f if not l.startswith("#")], delimiter="\t"):
                    self.p[d["type"]] = float(d["on_demand_usd_per_h"])
        for kv in [x for x in os.environ.get("AK2_ADVANCE_PRICES", "").split(",") if "=" in x]:
            k, v = kv.split("=", 1)
            self.p[k] = float(v)

    def __call__(self, t):
        if t not in self.p:
            q = subprocess.run(["truffle", "find", t, "--regions", "us-west-2", "--show-price", "-o", "json"], capture_output=True, text=True)
            price = None
            try:
                def walk(x):
                    if isinstance(x, dict):
                        if x.get("instance_type") == t and "on_demand_price" in x:
                            yield x["on_demand_price"]
                        for v in x.values():
                            yield from walk(v)
                    elif isinstance(x, list):
                        for v in x:
                            yield from walk(v)
                price = next(walk(json.loads(q.stdout)), None)
            except (ValueError, StopIteration):
                price = None
            if price is None:
                raise LookupError("no on-demand price for %s (truffle exit %d)" % (t, q.returncode))
            self.p[t] = float(price)
        return self.p[t]


def cost_limit(price, ttl_min):
    """mkspec-ladder.sh's rule: TTL x price + $0.005, to the cent (per member)."""
    return float("%.2f" % (price * ttl_min / 60.0 + 0.005))


# ---------------------------------------------------------------- the plan

def read_spec(root, rel):
    with open(os.path.join(root, rel)) as f:
        sp = json.load(f)
    body = sp["command"][2]
    line = next((l for l in body.split("\n") if l.startswith("RUNG=")), "")
    note = next((l for l in body.split("\n") if l.startswith("# TTL ")), "")
    wn = int(re.search(r"WANT_N=(\d+)", line).group(1))
    m = re.search(r"the estimated wall (\d+) s\).*?from (.*?): ([0-9a-z,-]+) \(the larger estimate", note)
    return {"type": sp["resources"]["instance_type"], "nodes": wn, "ttl_min": int(sp["lifecycle"]["ttl"].rstrip("m")),
            "cost": float(sp["lifecycle"]["cost_limit"]), "line": line, "est_s": m.group(1) if m else "",
            "basis": ("%s: %s" % (m.group(2), m.group(3))) if m else ("the c1 TTL of the table" if note else "")}


def params_line(rung, cohort, r):
    return "; ".join(["RUNG=%s" % rung, "ARM=%s" % r["arm"], "COHORT=%s" % cohort, "WANT_N=%d" % r["want_n"]] +
                     ["%s=%s" % (k, r["params"][k]) for k in LL.KEYS])


def git_tracked(root, rel):
    return subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", rel], capture_output=True).returncode == 0


def cost_of(rows, rung, cohort, r, prices, rec, res1, root):
    """(ttl_min, cost per member, est_s, basis text) for a resolved rung, as mkspec-ladder.sh makes them."""
    vcpus = LL.vcpus_of(r["instance"])
    if cohort == 1:
        ttl, est, basis = int(r["ttl_c1"]), "", "the c1 TTL of the table"
    else:
        e = TT.estimate(rows, rung, cohort, r["params"], r["instance"], vcpus, res1, rec, root)
        ttl, est, basis = e["ttl_min"], "%.0f" % e["est_s"], "%s: %s" % (e["how"], e["runs"])
    return ttl, cost_limit(prices(r["instance"]), ttl), est, basis


def mem_problem(r, cohort, root):
    """mkspec-ladder.sh's memory check, from the types table where the type is in it (else None: not judged here)."""
    t = LL.load_types().get(r["instance"])
    if t is None:
        return None
    pr = LL.fits(r, int(cohort), t[1], t[0])
    return "; ".join(pr) if pr else ""


def own_rows(rows, cohort):
    """A copy of ROWS with every conditional alias_cohorts entry at COHORT dropped: for a bound, each
    cost-chain rung is taken to run on its own (an alias would cost nothing), so its bound does not
    range over the time chain's selections as well."""
    out = []
    for r in rows:
        r = collections.OrderedDict(r)
        t, cond = LL.alias_decl(r, cohort)
        if t and cond:
            r["alias_cohorts"] = ";".join(d for d in r["alias_cohorts"].split(";") if not d.strip().startswith("c%d:" % cohort))
        out.append(r)
    return out


_COST_MEMO = {}


def bound(rows, rung, cohort, res, prices, rec, res1, root, cap=COMBO_CAP):
    """The largest cost_limit total of RUNG over every combination of the pending selections that
    decide it (each conditional alias_cohorts entry at the cohort taken as not holding: own_rows):
    (total or None, combos tried, combos that resolved, Counter of refusals)."""
    rows = own_rows(rows, cohort)
    names = LL.by_name(rows)
    deps = closure(rows, row_deps(rows, names[rung], cohort), cohort)
    pend = sorted(s for s in deps if (s, str(cohort), "alias") not in res and not LL.not_run_at(names[s], cohort))
    doms = [applicable(rows, names[s], cohort) for s in pend]
    n = 1
    for d in doms:
        n *= max(1, len(d))
    if n > cap:
        return None, n, 0, collections.Counter({"more than %d combinations: not enumerated" % cap: 1})
    best, ok, why = None, 0, collections.Counter()
    for combo in itertools.product(*doms):
        h = dict(res)
        for s, w in zip(pend, combo):
            h[(s, str(cohort), "alias")] = (w, "hypothetical")
        try:
            r = LL.resolve(rows, rung, cohort, res=h, root=root)
        except (LL.Unresolved, ValueError) as e:
            why[re.sub(r"\d+(\.\d+)? ?(GiB|GB|s)\b", "#", str(e))[:300]] += 1
            continue
        key = (rung, cohort, r["instance"], tuple(sorted(r["params"].items())))
        if key not in _COST_MEMO:
            mp = mem_problem(r, cohort, root)
            if mp:
                _COST_MEMO[key] = ("memory: " + mp[:200], None)
            else:
                try:
                    _COST_MEMO[key] = (None, cost_of(rows, rung, cohort, r, prices, rec, res1, root))
                except (LookupError, ValueError) as e:
                    _COST_MEMO[key] = (str(e)[:300], None)
        err, got = _COST_MEMO[key]
        if err:
            why[err] += 1
            continue
        ttl, c, _, _ = got
        ok += 1
        tot = c * r["want_n"]
        if best is None or tot > best:
            best = tot
    return best, n, ok, why


def plan(rows, cohort, res, root, prices, rec, res1, with_bounds=True):
    """[entry] for every run rung, and [selection status], at COHORT under RES."""
    names = LL.by_name(rows)
    stg = stages(rows, cohort)
    out = []
    for row in rows:
        if row["status"] != "run":
            continue
        n = row["rung"]
        e = {"rung": n, "arm": row["arm"], "stage": stg[n], "spec": "", "type": "", "nodes": "", "ttl_min": "", "cost": "",
             "total": "", "est_s": "", "basis": "", "bound": "", "waits": [], "note": "", "line": ""}
        try:
            r = LL.resolve(rows, n, cohort, res=res, root=root)
        except (LL.Unresolved, ValueError) as x:
            st, waits = classify(str(x))
            e.update(state=st, waits=waits, note=str(x))
            if st == "pending" and with_bounds:
                b, tried, okn, why = bound(rows, n, cohort, res, prices, rec, res1, root)
                e["bound_total"] = b
                e["bound"] = ("max over %d of %d hypothetical selection(s)" % (okn, tried)) + (
                    "; refused under %d: %s" % (sum(why.values()), "; ".join("%s (x%d)" % (k, v) for k, v in why.most_common(3))) if why else "")
                if b is not None:
                    e["total"] = "%.2f" % b
            out.append(e)
            continue
        rel = spec_rel(n, cohort)
        e.update(spec=rel, type=r["instance"], nodes=r["want_n"], line=params_line(n, cohort, r))
        tracked = git_tracked(root, rel)
        if tracked and os.path.exists(os.path.join(root, rel)):
            s = read_spec(root, rel)
            e.update(state="committed", ttl_min=s["ttl_min"], cost=s["cost"], total="%.2f" % (s["cost"] * s["nodes"]),
                     est_s=s["est_s"], basis=s["basis"])
            if s["line"] != e["line"]:
                e["note"] = "STALE: the committed spec's parameters are not the resolution's now (make ladder-respec COHORT=%d)" % cohort
        else:
            mp = mem_problem(r, cohort, root)
            if mp:
                e.update(state="blocked", note="memory: " + mp)
                out.append(e)
                continue
            try:
                ttl, c, est, basis = cost_of(rows, n, cohort, r, prices, rec, res1, root)
            except (LookupError, ValueError) as x:
                e.update(state="blocked", note=str(x))
                out.append(e)
                continue
            e.update(state="new", ttl_min=ttl, cost=c, total="%.2f" % (c * r["want_n"]), est_s=est, basis=basis)
            if ttl * 60 > TT.max_ttl_s(root):
                e.update(state="blocked", note="TTL %d min is above AK2_MAX_TTL_S (%d min): run.sh refuses it" % (ttl, TT.max_ttl_s(root) // 60))
        out.append(e)
    return out, selections(rows, cohort, res, stg, out)


def selections(rows, cohort, res, stg, entries):
    """[{'rung', 'stage', 'state', 'why'}] for every selection (a rung with a select rule) at COHORT."""
    names = LL.by_name(rows)
    by = {e["rung"]: e for e in entries}
    out = []
    for row in rows:
        if not is_selection(row):
            continue
        s = row["rung"]
        d = {"rung": s, "stage": stg.get(s, ""), "state": "", "why": ""}
        nr = LL.not_run_at(row, cohort)
        hit = res.get((s, str(cohort), "alias"))
        if nr:
            p = LL.run_pred_at(rows, row, cohort)
            d.update(state="not-run", why="%s: its tokens resolve to %s's values" % (nr, p["rung"] if p else "-"))
        elif hit:
            d.update(state="resolved", why="%s (%s)" % (hit[0], hit[1]))
        else:
            app = applicable(rows, row, cohort)
            parts, waiting = [], set()
            for c in app:
                ce = by.get(c)
                if names[c]["status"].startswith("alias:"):
                    parts.append("%s (an alias: %s)" % (c, "resolved" if res.get((c, str(cohort), "alias")) else "pending"))
                    if not res.get((c, str(cohort), "alias")):
                        waiting.add(c)
                elif LL.not_run_at(names[c], cohort):
                    parts.append("%s (the predecessor, not run here: its run ancestor's configuration)" % c)
                elif ce is None:
                    parts.append(c)
                else:
                    parts.append("%s (%s)" % (c, ce["state"]))
                    waiting |= set(ce["waits"])
            left = [c for c in row["alias_of"].split("|") if c and c not in app]
            st = "pending"
            if len(app) < 2 and not LL.RANGE_RE.search(row["select"]):
                st = "BLOCKED"
                why = ("only %s applies at c%d (%s): the rule needs two candidates, so this cohort needs candidate rows or a "
                       "not_run_cohorts entry (a table decision)" % (", ".join(app) or "none", cohort,
                                                                   "; ".join("%s: %s" % (c, LL.not_run_at(names[c], cohort)) for c in left)[:400]))
            elif waiting:
                why = "waits on selection(s) %s before its candidates are determined; candidates: %s" % (", ".join(sorted(waiting)), "; ".join(parts))
            else:
                why = ("waits on the campaign: every candidate needs n >= 2 measured runs at c%d (then make ladder-select); candidates: %s"
                       % (cohort, "; ".join(parts)))
            if LL.RANGE_RE.search(row["select"]):
                why += "; its in-flight range (vCPUs / THREADS on the predecessor's host) is computed once its predecessor resolves"
            d.update(state=st, why=why)
        out.append(d)
    return out


# ---------------------------------------------------------------- output

def fleet_class(e):
    """(classifier, upload, fleet shape) of a determined spec, from its PARAMS line."""
    kv = dict(x.split("=", 1) for x in e["line"].split("; ") if "=" in x)
    vcpus = LL.vcpus_of(e["type"]) or 0
    w = kv["INFLIGHT"] if kv["CLASSIFIER"] == "ours-engine" else kv["PROCS"]
    lanes = 1 if w == "-" else LL.vc(w, vcpus)
    shape = "%s node(s) (%s replica(s) x %s shard(s)), %s" % (e["nodes"], kv["REPLICAS"], kv["SHARDS"],
                                                            "1 lane" if lanes == 1 else "several lanes")
    return (kv["CLASSIFIER"], kv["OUT_UPLOAD"], shape), lanes


def write_plan(root, cohort, entries):
    d = os.path.join(root, "results", "g3", "ladder-advance")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "c%d.plan.tsv" % cohort)
    with open(p + ".tmp", "w") as f:
        f.write("# make ladder-advance COHORT=%d (scripts/lib/ladder_advance.py; docs/ladder.md, \"Advancing a cohort\"): every run rung's\n"
                "# state, stage, spec and cost_limit at the cohort. For a pending rung, cost_limit_total_usd is the bound: the largest over\n"
                "# every combination of the pending selections it depends on. est_s and basis are the TTL estimate's (scripts/lib/ladder_ttl.py).\n"
                % cohort)
        f.write("\t".join(PLAN_COLS) + "\n")
        for e in sorted(entries, key=lambda e: (e["stage"], [r for r in ORDER].index(e["rung"]) if e["rung"] in ORDER else 0)):
            vals = {"cohort": cohort, "stage": e["stage"], "rung": e["rung"], "arm": e["arm"], "state": e["state"], "spec": e["spec"],
                    "type": e["type"], "nodes": e["nodes"], "ttl_min": e["ttl_min"], "cost_limit_usd": e["cost"],
                    "cost_limit_total_usd": e["total"], "est_s": e["est_s"], "basis": e["basis"], "bound": e["bound"],
                    "waits_on": ",".join(e["waits"]), "note": e["note"]}
            f.write("\t".join(str(vals[c]).replace("\t", " ").replace("\n", " ") for c in PLAN_COLS) + "\n")
    os.replace(p + ".tmp", p)
    return os.path.relpath(p, root)


ORDER = []


def report(cohort, entries, sels, new, say):
    st = sorted({e["stage"] for e in entries} | {s["stage"] for s in sels if s["stage"]})
    say("")
    say("stage plan at c%d (cost_limit totals are TTL x on-demand price x nodes: upper bounds; a pending rung's is the largest over"
        " the pending selections it depends on):" % cohort)
    grand = 0.0
    for k in st:
        es = [e for e in entries if e["stage"] == k and e["state"] not in ("not-run", "alias", "out")]
        if not es:
            continue
        tot = sum(float(e["total"]) for e in es if e["total"])
        unk = [e["rung"] for e in es if not e["total"]]
        grand += tot
        waits = sorted({w for e in es for w in e["waits"]})
        sel_here = [s["rung"] for s in sels if s["stage"] == k and s["state"] in ("pending", "BLOCKED")]
        say("  stage %d: %d rung(s), cost_limit total <= $%.2f per rep%s; waits on: %s; then selects: %s" % (
            k, len(es), tot, (" (no bound for %s)" % ", ".join(unk)) if unk else "", ", ".join(waits) or "nothing (determined)",
            ", ".join(sel_here) or "-"))
        for e in es:
            say("    %-15s %-9s %-15s %3s node(s) TTL %4s min  $%8s  %s" % (
                e["rung"], e["state"], e["type"] or "-", e["nodes"] or "-", e["ttl_min"] or "-", e["total"] or "-",
                (e["bound"] if e["state"] == "pending" else e["note"])[:240]))
    say("  all stages: cost_limit total <= $%.2f per rep (make ladder-campaign runs REPS=2: x2)" % grand)
    skipped = [e for e in entries if e["state"] in ("not-run", "alias", "out")]
    if skipped:
        say("  not generated at c%d: %s" % (cohort, "; ".join("%s (%s)" % (e["rung"], e["state"]) for e in skipped)))
    say("")
    say("selections at c%d:" % cohort)
    for s in sels:
        say("  %-11s stage %-2s %-9s %s" % (s["rung"], s["stage"], s["state"], s["why"][:600]))
    blockers = [e for e in entries if e["state"] in ("collapsed", "blocked")] + [s for s in sels if s["state"] == "BLOCKED"]
    say("")
    if blockers:
        say("blockers at c%d (each needs a decision or a table change before its stage):" % cohort)
        for b in blockers:
            say("  %s: %s" % (b["rung"], (b.get("note") or b.get("why"))[:600]))
    else:
        say("blockers at c%d: none among the determined rungs" % cohort)
    for e in entries:
        if e["state"] == "pending" and "refused under" in e["bound"]:
            say("  note: %s resolves under only some hypothetical selections: %s" % (e["rung"], e["bound"][:500]))


def run(cmd, root, env=None):
    p = subprocess.run(cmd, cwd=root, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout + p.stderr


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["advance", "plan"])
    ap.add_argument("cohort")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-select", action="store_true")
    ap.add_argument("--root", default=LL.ROOT)
    a = ap.parse_args(argv)
    if not re.fullmatch(r"[1-9][0-9]*", a.cohort):
        print("ladder-advance: COHORT %r is not an integer >= 1" % a.cohort, file=sys.stderr)
        return 2
    cohort, root = int(a.cohort), os.path.abspath(a.root)
    dry = a.dry_run or a.cmd == "plan"
    say = lambda s: print("ladder-advance: " + s if s else "", flush=True)   # noqa: E731
    lev = os.path.join(root, "scripts", "g3", "ladder.levers.tsv")
    resp = os.path.join(root, "scripts", "g3", "ladder.resolved.tsv")
    rows = LL.load(lev)
    ORDER[:] = [r["rung"] for r in rows]
    probs = LL.check(rows)
    if probs:
        say("refused: the lever table fails make ladder-check:\n  " + "\n  ".join(probs))
        return 3
    say("cohort %d%s: %s" % (cohort, " (DRY_RUN: nothing is selected, generated or written)" if dry else "",
                             "plan only" if a.cmd == "plan" else "select, generate, check"))
    # 1. Selection (make ladder-select; DRY_RUN passed on).
    wrote_sel = False
    if a.cmd == "advance" and not a.no_select:
        env = dict(os.environ, DRY_RUN="1" if dry else "")
        rc, out = run(["scripts/g3/ladder-select.sh", str(cohort)], root, env)
        for l in out.splitlines():
            if l.startswith("ladder-select: ") and not l.startswith("ladder-select: shell flags"):
                say("  " + l)
        if rc != 0:
            say("refused: make ladder-select exited %d (above); nothing is generated" % rc)
            return 3
        wrote_sel = "wrote " in out and "row(s) to scripts/g3/ladder.resolved.tsv" in out
        if dry and "DRY_RUN: would write" in out:
            say("  DRY_RUN: the selections ladder-select would write are not applied below")
    try:
        res = LL.read_resolved(resp, root, rows)
    except ValueError as e:
        say("refused: %s" % e)
        return 3
    for w in LL.notrun_resolution_warnings(rows, res):
        say("warning: %s" % w)
    res1 = {k: v for k, v in res.items() if k[1] == "1"}
    prices = Prices(root)
    rec = TT.c1_record(root)
    # 2. Generation, until a pass generates nothing new.
    generated, failed = [], []
    for npass in range(1, 6):
        entries, sels = plan(rows, cohort, res, root, prices, rec, res1, with_bounds=False)
        todo = [e for e in entries if e["state"] == "new" and e["rung"] not in generated and e["rung"] not in [f[0] for f in failed]]
        if dry or not todo:
            break
        for e in todo:
            rc, out = run(["scripts/g3/mkspec-ladder.sh", e["arm"], e["rung"], str(cohort)], root)
            for l in out.strip().splitlines():
                say("  " + l)
            (generated if rc == 0 else failed).append(e["rung"] if rc == 0 else (e["rung"], "mkspec-ladder.sh exit %d" % rc))
    entries, sels = plan(rows, cohort, res, root, prices, rec, res1, with_bounds=True)
    for e in entries:
        if e["rung"] in generated and e["state"] != "committed":
            e["state"] = "new"
        for f in failed:
            if f[0] == e["rung"]:
                e.update(state="blocked", note=f[1] + " (above)")
    new = [e for e in entries if e["state"] == "new"]
    # 3. The static checks.
    bad = False
    for cmd in (["python3", "scripts/lib/ladder_levers.py", "check"], ["python3", "scripts/lib/ladder_body_compat.py", "check"],
                ["python3", "scripts/lib/ladder_body_compat.py", "fresh"]):
        rc, out = run(cmd, root)
        last = [l for l in out.strip().splitlines() if l.startswith(("ladder_levers: ", "ladder_body_compat: "))]
        say("check %s: exit %d%s" % (" ".join(cmd[1:]), rc, (": " + last[-1][:200]) if last else ""))
        if rc != 0:
            bad = True
            for l in out.strip().splitlines()[-15:]:
                say("    " + l)
    # 4. The report and the plan table.
    report(cohort, entries, sels, new, say)
    if not dry:
        say("")
        say("plan table: %s" % write_plan(root, cohort, entries))
    # 5. What the coordinator does next.
    say("")
    if new:
        say("%s spec(s) at c%d%s: %s" % (len(new), cohort, " that would be generated" if dry else " generated now, uncommitted",
                                         ", ".join(e["spec"] for e in new)))
        classes = collections.OrderedDict()
        for e in new:
            k, lanes = fleet_class(e)
            classes.setdefault(k, []).append((e, lanes))
        say("rehearsal classes (classifier, upload, fleet shape): one make rehearse SPEC= each:")
        for k, es in classes.items():
            rep = max(es, key=lambda x: (x[1], -ORDER.index(x[0]["rung"])))[0]
            say("  %s / %s / %s: %s; representative %s" % (k[0], k[1], k[2], ", ".join(x[0]["rung"] for x in es), rep["spec"]))
    else:
        say("no new spec at c%d" % cohort)
    pend = [s["rung"] for s in sels if s["state"] in ("pending", "BLOCKED")]
    say("selections pending at c%d: %s" % (cohort, ", ".join(pend) or "none"))
    if wrote_sel:
        say("ladder-select wrote scripts/g3/ladder.resolved.tsv and a snapshot under results/g3/ladder-select/: commit them first")
    if not dry and (new or wrote_sel):
        say("STOP: the coordinator must now commit the new specs%s, run make rehearse SPEC=<each representative above> and "
            "make dryrun-userdata (nothing in flight), then make ladder-campaign COHORT=%d; after the campaign, make "
            "ladder-advance COHORT=%d again (it runs make ladder-select first). Nothing was launched or committed."
            % (" and the resolved rows" if wrote_sel else "", cohort, cohort))
    elif not dry:
        say("STOP: nothing new to generate; the pending selections above wait on their candidates' runs (make ladder-campaign "
            "COHORT=%d) or on a decision (blockers). Nothing was launched or committed." % cohort)
    if failed:
        return 1
    return 3 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
