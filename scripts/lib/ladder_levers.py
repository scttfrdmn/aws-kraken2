#!/usr/bin/env python3
"""The #25 ladder lever table (scripts/g3/ladder.levers.tsv; #51, docs/ladder.md): load, check, resolve.

  ladder_levers.py check [TSV]                      every rung changes exactly one key-group (Law 5)
  ladder_levers.py params RUNG COHORT [--mem-mib M --vcpus V] [--tsv TSV] [--resolved RES]
                                                    the rung's resolved PARAMs as shell-safe lines, for
                                                    scripts/g3/mkspec-ladder.sh; exit 3 if any value is
                                                    still a placeholder, 4 if the type cannot hold it
  ladder_levers.py spec-params SPEC.json [--rep N]  the spec's `params` object for manifest.json and
                                                    cohort.json (null if not a ladder spec). --rep N
                                                    (AK2_LADDER_REP, set by make ladder-campaign) adds
                                                    rep N and rep_source; exit 3 on a non-ladder spec,
                                                    a bad N, or a PARAMS block with another REP
  ladder_levers.py az-alt TYPE AZ                   the AZ list (scripts/g3/ladder.azs.tsv) row for
                                                    TYPE in AZ as JSON, its evidence checked; exit 3
                                                    if it is not listed or its evidence does not hold
  ladder_levers.py --self-test

Importable (the fuller ladder_check.py of #53 builds on it): load(), check(), resolve(), changed(),
coupled_keys(), spec_params(), GROUP, KEYS.

The one-lever rule (check): a rung's PARAMs and instance type are compared with its predecessor's.
The changed keys, less the keys its `coupled` column names (each with its reason), must all fall in
one key-group, the rung's `group`. Every coupled key must really change (no stale coupling) and lie
outside that group. The instance type is the key-group HOST. Every S* candidate and endpoint rung
(S9, Sstar-r8g, Sstar-r8gd, Sstar-time, Sstar-cost) has S9's PARAMs and differs only in host.
`lever` is what #52's tables report: the group, except stock (S0-T1), threads (S0-Tv) and
rapidgzip (S5). Every rung names a counterpart rung on the other ladder that exists, or says
"none: <reason>". ETAG_CHECK is on in every row. Each (cohort, endpoint) for cohorts 1, 10, 100
and 1000 is declared on exactly one rung of its arm (the `endpoint` column).
"""
import collections
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TSV = os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv")
RESOLVED = os.path.join(ROOT, "scripts", "g3", "ladder.resolved.tsv")
RUNS = os.path.join(ROOT, "results", "cohort", "PRJNA398089", "runs.tsv")
AZS = os.path.join(ROOT, "scripts", "g3", "ladder.azs.tsv")
TYPES = os.path.join(ROOT, "scripts", "g3", "ladder.types.tsv")
REP_SOURCE = "AK2_LADDER_REP at launch (make ladder-campaign)"

KEYS = ("CLASSIFIER THREADS PROCS DB_STAGE DB_PLACE DB_LOAD HOST_TUNES GUNZIP IN_FETCH IN_CLIENT IN_DEST "
        "OUT_UPLOAD REPLICAS SHARDS PLACEMENT INFLIGHT SETUP ETAG_CHECK").split()
GROUPS = ["CLASSIFIER", "THREADS+PROCS", "DB_STAGE", "DB_PLACE+DB_LOAD", "HOST_TUNES", "GUNZIP",
          "IN_FETCH+IN_CLIENT+IN_DEST", "OUT_UPLOAD", "REPLICAS+SHARDS", "PLACEMENT", "INFLIGHT", "SETUP",
          "ETAG_CHECK", "HOST"]
GROUP = {k: g for g in GROUPS for k in g.split("+")}
GROUP["instance"] = "HOST"
COLS = ["rung", "arm", "status", "not_run_cohorts", "alias_cohorts", "alias_of", "select", "derived", "predecessor", "lever", "group", "coupled", "counterpart", "phase", "endpoint",
        "pred_wall_s", "pred_usd", "pred_phase_s", "instance", "az", "ttl_min_c1"] + KEYS + ["note"]
LABELS = {"S0-T1": "stock", "S0-Tv": "threads", "S2c": "IN_DEST", "S3": "host-tunes", "S5": "rapidgzip"}   # lever labels #52's tables read; others: the group
ENDPOINTS = {"S": ("S*-time", "S*-cost"), "O": ("O*-time", "O*-cost")}
COHORTS = (1, 10, 100, 1000)
SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
# Allowed literal values (ladder.body.sh checks the same); placeholders start with @.
ALLOWED = {
    "CLASSIFIER": r"upstream|ours-plain|ours-engine", "THREADS": r"vcpus|vcpus/[1-9][0-9]*|[1-9][0-9]*", "PROCS": r"vcpus/[1-9][0-9]*|[1-9][0-9]*",
    "DB_STAGE": r"awscp-default|s5cmd|ranged-get", "DB_PLACE": r"nvme|tmpfs|tmpfs-huge|memory", "DB_LOAD": r"load|mmap|resident",
    "HOST_TUNES": r"none|precompact|proactive|defer|defermadv|always", "GUNZIP": r"gzip|rapidgzip-P([1-9][0-9]*|auto)",
    "IN_FETCH": r"serial|lanes[1-9][0-9]*", "IN_CLIENT": r"default|classic|crt", "IN_DEST": r"nvme|tmpfs",
    "OUT_UPLOAD": r"awscp-default|s5cmd-serial|s5cmd-overlap|sdk-stream", "REPLICAS": r"[1-9][0-9]*",
    "SHARDS": r"[1-9][0-9]*", "PLACEMENT": r"mod|lpt", "INFLIGHT": r"-|vcpus/[1-9][0-9]*|[1-9][0-9]*", "SETUP": r"serial|overlap",
    "ETAG_CHECK": r"on",
}
HASH_BYTES = 1189091671800       # RODA v205 hash.k2d (docs/engine.md)
OUT_BYTES_PER_PAIR = 150         # --output + --report, with margin (an 8 MiB-part output of SRR5935740: about 90 B per pair)
OS_SLACK = 16 << 30
NVME_BYTES = {"r8gd.48xlarge": 1900 * 10 ** 9}   # one instance-store device (S0: one device, Scott 2026-10-09)
PARAMS_MARK = "# Parameters (scripts/g3/mkspec-ladder.sh"
# The O arm's thread ratio (Scott, 2026-10-13, ruling 1; docs/ladder.md, "The O arm's thread ratio"):
# `@ratio:<rung>` (THREADS) is vcpus/R and `@ratio:<rung>:fill` (PROCS or INFLIGHT) is fill/R, with
# R = <rung>'s vCPUs / <rung>'s THREADS, both as resolved at <rung>'s host (the O arm's S* root).
# fill/R is vcpus // max(1, vcpus // R): as many samples at once as vcpus/R threads leave room for,
# so P x T <= vCPUs on every host. The body has no fill form, so resolve() gives its value at the
# rung's own (pinned) type.
RATIO_RE = re.compile(r"@ratio:([A-Za-z0-9-]+)(:fill)?")
FILL_RE = re.compile(r"fill/([1-9][0-9]*)(?:/([1-9][0-9]*))?")   # fill/R, or fill/R/C clamped to the cohort C
# The family whose small sizes a right-sized @floor uses (Scott, 2026-10-13, ruling 3): r8gd has no
# small sizes; r8g is its generation and memory ratio, and ours does not use the instance store.
FLOOR_FAMILY = {"r8gd": "r8g"}
# `@fit:<family>` (an instance): the family's smallest non-metal type that holds the rung at the
# cohort by fits(), with every other PARAM as resolved (O2's candidates, one per family, at O1's N).
FIT_RE = re.compile(r"@fit:([a-z0-9]+)")


class Unresolved(Exception):
    pass


def load(path=TSV):
    rows = []
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f if not l.startswith("#") and l.strip()]
    head = lines[0].split("\t")
    if head != COLS:
        raise ValueError("%s: columns %s, want %s" % (path, head, COLS))
    for l in lines[1:]:
        f = l.split("\t")
        if len(f) != len(COLS):
            raise ValueError("%s: row %r has %d fields, want %d" % (path, f[0], len(f), len(COLS)))
        rows.append(collections.OrderedDict(zip(COLS, f)))
    return rows


def coupled_keys(row):
    """The keys the coupled column names: 'A+B: reason; C: reason'."""
    out = set()
    for m in re.finditer(r"(?:^|; )((?:[A-Z_]+\+)*[A-Z_]+): ", row.get("coupled", "")):
        out.update(m.group(1).split("+"))
    return out


def by_name(rows):
    return {r["rung"]: r for r in rows}


def pred_of(rows, row):
    p = row["predecessor"]
    if p == "-":
        return None
    if p == "@Sstar":
        return by_name(rows).get("S9")
    return by_name(rows).get(p)


def instance_of(rows, row):
    i = row["instance"]
    if i == "=pred":
        if row["predecessor"].startswith("@"):
            return row["predecessor"]   # the host of an endpoint chosen from the record
        p = pred_of(rows, row)
        return "@unresolved-predecessor" if p is None else instance_of(rows, p)
    return i


def derived_host(rows, row, _seen=None):
    """Whether the rung's host is a derived move with its lever (O3-n<K>: the family's smallest type
    that holds table/K moves with SHARDS, as S4's vCPU ratios move with the host). The one-lever
    check then counts the host change as derived, not as the HOST group. Honoured only when all of
    these hold:
      - its `derived` column declares it, as an `instance: ...` clause;
      - its instance is `@floor:<its own predecessor>` (the predecessor's family, right-sized), or
        it is an alias whose instance is `@select:<itself>` and every candidate other than its
        predecessor qualifies the same way.
    Any other host change (a fixed type, a floor on another rung's family) stays the HOST group."""
    if re.search(r"(?:^|; )instance: ", row.get("derived", "")) is None:
        return False
    inst = row.get("instance", "")
    if inst == "@floor:%s" % row.get("predecessor", ""):
        return True
    if inst == "@select:%s" % row["rung"] and row.get("status", "").startswith("alias:"):
        names, seen = by_name(rows), (_seen or set()) | {row["rung"]}
        cands = [c for c in row.get("alias_of", "").split("|") if c and c != row.get("predecessor")]
        return bool(cands) and all(c in names and c not in seen and derived_host(rows, names[c], seen) for c in cands)
    return False


def canon(rows, v, depth=0):
    """A PARAM's text for the static one-lever check: `@ratio:<o>` is <o>'s own THREADS text and
    `@ratio:<o>:fill` its PROCS text, since at <o>'s host the ratio resolves to exactly those values
    (on another host it moves with the host, the host's lever: the `derived` column)."""
    m = RATIO_RE.fullmatch(v)
    o = by_name(rows).get(m.group(1)) if m else None
    if o is None or depth > 10:
        return v
    return canon(rows, o["PROCS" if m.group(2) else "THREADS"], depth + 1)


def changed(rows, row, pred):
    keys = [k for k in KEYS if canon(rows, row[k]) != canon(rows, pred[k])]
    if row["instance"] != "=pred" and instance_of(rows, row) != instance_of(rows, pred):
        keys.append("instance")
    return keys


def candidates_of(rows):
    """candidate rung -> the alias rung whose alias_of names it (the S* endpoints, and every selection's
    candidate rungs)."""
    return {c: r["rung"] for r in rows if r["status"].startswith("alias:") for c in r["alias_of"].split("|") if c}


# An alias_cohorts entry is `c<C>: <rung>` (unconditional: the two are one configuration there, and
# a declaration that turns out false is refused) or `c<C>: <rung> (if same configuration)`
# (conditional: an alias exactly where the two resolve to one configuration, an ordinary rung where
# they resolve and differ, and refused while either is unresolved).
COND = " (if same configuration)"
ALIAS_ENTRY = re.compile(r"c([1-9][0-9]*): (\S+)(%s)?" % re.escape(COND))


def alias_decl(row, cohort):
    """(the rung ROW's alias_cohorts entry names at COHORT, conditional?), or ('', False). Static:
    whether a conditional entry is an alias at COHORT is alias_state's to say."""
    for d in [d.strip() for d in row.get("alias_cohorts", "").split(";") if d.strip()]:
        c, _, t = d.partition(":")
        if c.strip() == "c%s" % cohort:
            t = t.strip()
            return (t[:-len(COND)], True) if t.endswith(COND) else (t, False)
    return "", False


def alias_at(row, cohort):
    """The rung ROW's alias_cohorts entry names at COHORT, or '' (the declaration, conditional or
    not; alias_state decides a conditional one)."""
    return alias_decl(row, cohort)[0]


def alias_state(rows, row, cohort, res, depth=0, root=None):
    """(state, target, why) of ROW's alias_cohorts entry at COHORT under resolutions RES:
    ('none', '', '') without one; ('alias', t, '') for an unconditional entry, or a conditional one
    whose two rungs resolve to one configuration; ('own', t, why) for a conditional one whose two
    rungs resolve and differ (the rung is an ordinary rung there); ('undecided', t, why) for a
    conditional one while either rung is unresolved."""
    t, cond = alias_decl(row, cohort)
    if not t:
        return "none", "", ""
    if not cond:
        return "alias", t, ""
    names = by_name(rows)
    if t not in names:
        return "undecided", t, "no rung %s" % t
    a, abad = _values(rows, row, cohort, res, depth + 1)
    b, bbad = _values(rows, names[t], cohort, res, depth + 1)
    if abad or bbad:
        return "undecided", t, "unresolved: %s" % ", ".join(["%s %s" % (row["rung"], x) for x in abad] +
                                                             ["%s %s" % (t, x) for x in bbad])
    if not same_config(a, b):
        return "own", t, "configurations differ in %s" % ",".join(k for k in KEYS + ["instance"] if a[k] != b[k])
    # One configuration, but the target has no runs to read there: it is not run at the cohort, or it
    # is outside its own alias's bracket or range (or is that alias's predecessor's configuration).
    # Then the entry is no alias, and the rung reads its own runs.
    nr = not_run_at(names[t], cohort, rows, res)
    if nr:
        return "own", t, "its target %s is %s" % (t, nr)
    try:
        out = candidate_out(rows, t, cohort, res, root or ROOT)
    except Unresolved as e:
        return "undecided", t, "its target %s's candidacy is unresolved (%s)" % (t, e)
    if out:
        return "own", t, "its target %s is %s at c%s: not a candidate there, so it has no runs to read" % (t, out, cohort)
    return "alias", t, ""


def check(rows):
    probs = []
    names = by_name(rows)
    candidate_of = candidates_of(rows)
    if len(names) != len(rows):
        probs.append("duplicate rung names")
    for r in rows:
        n = r["rung"]
        for k in KEYS:
            v = r[k]
            if not v.startswith("@") and not re.fullmatch(ALLOWED[k], v):
                probs.append("%s: %s=%s is not an allowed value (%s)" % (n, k, v, ALLOWED[k]))
        if r["ETAG_CHECK"] != "on":
            probs.append("%s: ETAG_CHECK is %s, want on" % (n, r["ETAG_CHECK"]))
        cl = r["CLASSIFIER"]
        if r["arm"] not in ("S", "O"):
            probs.append("%s: arm %s (S or O)" % (n, r["arm"]))
        if r["arm"] == "S" and cl != "upstream":
            probs.append("%s: arm S runs upstream, not %s" % (n, cl))
        if r["arm"] == "O" and cl == "upstream":
            probs.append("%s: arm O runs ours" % n)
        want = LABELS.get(n, r["group"])
        if r["lever"] != want:
            probs.append("%s: lever %s, want %s (stock marks S0-T1 only; S0-Tv is threads; else the group)" % (n, r["lever"], want))
        if not re.fullmatch(r"run:[a-z0-9.-]+(\+run:[a-z0-9.-]+)*", r["phase"]):
            probs.append("%s: phase %r is not run:NAME[+run:NAME...]" % (n, r["phase"]))
        cp = r["counterpart"]
        if not cp.startswith("none: ") or len(cp) < 12:
            for c in [c.strip() for c in cp.split(",")]:
                if c not in names:
                    probs.append("%s: counterpart %r is neither a rung nor 'none: <reason>'" % (n, c))
        st = r["status"]
        if st != "run" and not re.fullmatch(r"(not-run|alias): .{8,}", st):
            probs.append("%s: status %r (run, not-run: <reason> or alias: <rule>)" % (n, st))
        for d in [d.strip() for d in r["not_run_cohorts"].split(";") if d.strip()]:
            if not re.fullmatch(r"c[1-9][0-9]*: .{8,}", d):
                probs.append("%s: not_run_cohorts entry %r is not c<cohort>: <reason>" % (n, d))
        # not_run_cohorts: a selecting rung, a selection's candidate, or a rung whose values derive
        # from a selection (an @select token), each where its selection leaves its predecessor's configuration.
        derives = any(r[k].startswith(("@select:", "@ratio:")) for k in KEYS) or r["instance"].startswith("@select:")
        for k in KEYS:
            m = RATIO_RE.fullmatch(r[k]) if r[k].startswith("@ratio:") else None
            if r[k].startswith("@ratio:") and (m is None or m.group(1) not in names or k not in VC_KEYS
                                               or (k == "THREADS") == bool(m.group(2))):
                probs.append("%s: %s=%s: @ratio:<rung> is THREADS only, @ratio:<rung>:fill PROCS or INFLIGHT only, "
                             "<rung> a rung" % (n, k, r[k]))
        if r["instance"].startswith("@fit:") and not FIT_RE.fullmatch(r["instance"]):
            probs.append("%s: instance %s is not @fit:<family>" % (n, r["instance"]))
        if r["not_run_cohorts"] and not (r["select"] or n in candidate_of or derives):
            probs.append("%s: not run at some cohorts, but it makes, is or derives from no selection there" % n)
        for d in [d.strip() for d in r.get("alias_cohorts", "").split(";") if d.strip()]:
            m = ALIAS_ENTRY.fullmatch(d)
            if not m:
                probs.append("%s: alias_cohorts entry %r is not c<cohort>: <rung>[%s]" % (n, d, COND))
                continue
            # A conditional entry is decided on the two rungs' resolved values, so the rung must make
            # no selection of its own (its values would then depend on runs it may never have).
            own = r["select"] or any((token(r[k], k) or ("", ""))[0] == n for k in KEYS + ["instance"])
            if m.group(3) and own:
                probs.append("%s: a conditional alias_cohorts entry (c%s) on a rung that makes a selection" % (n, m.group(1)))
            t = names.get(m.group(2))
            if t is None or t["rung"] == n or t["arm"] != r["arm"] or t["status"].startswith("not-run"):
                probs.append("%s: alias_cohorts c%s names %s, not another rung of arm %s that is run" % (n, m.group(1), m.group(2), r["arm"]))
            if st != "run":
                probs.append("%s: alias_cohorts on a rung whose status is %r (want run)" % (n, st))
            # Both at one cohort only when both are conditional (the not-run is decided first).
            nrw, nrc = notrun_decl(r, m.group(1))
            if (nrw or nrc) and not (nrc and m.group(3)):
                probs.append("%s: c%s is both in not_run_cohorts and alias_cohorts" % (n, m.group(1)))
        if st.startswith("alias:"):
            cands = [c for c in r["alias_of"].split("|") if c]
            if not cands or any(c not in names or not (names[c]["status"] == "run" or names[c]["status"].startswith("alias:"))
                                for c in cands):
                probs.append("%s: an alias needs alias_of naming run or alias rungs (%r)" % (n, r["alias_of"]))
            for c in cands:
                if c in names and c != r["predecessor"] and names[c]["predecessor"] != r["predecessor"]:
                    probs.append("%s: candidate %s's predecessor is %s, not the alias's predecessor %s"
                                 % (n, c, names[c]["predecessor"], r["predecessor"]))
                if c in names and c != r["predecessor"] and names[c]["group"] != r["group"]:
                    probs.append("%s: candidate %s changes %s, not the alias's group %s" % (n, c, names[c]["group"], r["group"]))
            if not r["select"]:
                probs.append("%s: an alias needs its select rule" % n)
        elif r["alias_of"]:
            probs.append("%s: alias_of on a rung that is not an alias" % n)
        pr = names.get(r["predecessor"])
        if pr is not None and pr["status"].startswith("not-run"):
            probs.append("%s: predecessor %s is not run (%s); name the rung before it" % (n, pr["rung"], pr["status"]))
        # A selection made at this rung needs its registered rule, and a rule needs a selection.
        own = any((token(r[k], k) or ("", ""))[0] == n for k in KEYS) or (token(r["instance"], "instance") or ("", ""))[0] == n
        if own and not r["select"]:
            probs.append("%s: makes a @select:%s selection without a select rule" % (n, n))
        if r["select"] and not own:
            probs.append("%s: has a select rule but makes no @select:%s selection" % (n, n))
        if r["select"] and not all(w in r["select"] for w in ("candidates", "ties")):
            probs.append("%s: its select rule must name the candidates, the axis and the ties" % n)
        if r["predecessor"] == "-":
            if r["group"] != "-":
                probs.append("%s: the root changes no key-group (group '-')" % n)
            continue
        p = pred_of(rows, r)
        if p is None:
            probs.append("%s: predecessor %s not found" % (n, r["predecessor"]))
            continue
        ch = changed(rows, r, p)
        co = coupled_keys(r)
        free = [k for k in ch if k not in co and not (k == "instance" and derived_host(rows, r))]
        groups = sorted({GROUP[k] for k in free})
        if st.startswith("not-run"):
            if ch:
                probs.append("%s: is %s but changes %s against %s" % (n, st, ",".join(ch), p["rung"]))
            continue
        if r["group"] not in GROUPS:
            probs.append("%s: group %s is not a key-group (%s)" % (n, r["group"], " ".join(GROUPS)))
        if groups != [r["group"]]:
            probs.append("%s: changes %s (key-groups %s) against %s; want exactly the group %s%s" % (
                n, ",".join(ch) or "nothing", ",".join(groups) or "none", p["rung"], r["group"],
                " (coupled: %s)" % ",".join(sorted(co)) if co else ""))
        for k in sorted(co):
            if k not in ch:
                probs.append("%s: coupled %s does not change against %s (stale)" % (n, k, p["rung"]))
            elif GROUP[k] == r["group"]:
                probs.append("%s: coupled %s is in the lever's own group %s" % (n, k, r["group"]))
    for c in ("Sstar-r8g", "Sstar-r8gd", "Sstar-time", "Sstar-cost"):
        if c in names and "S9" in names and any(names[c][k] != names["S9"][k] for k in KEYS):
            probs.append("%s differs from S9 in PARAMs (every S* candidate and endpoint rung has S9's)" % c)
    # Endpoints: each (cohort, endpoint) declared on exactly one rung of its arm, before any run.
    seen = {}
    for r in rows:
        for d in [d.strip() for d in r["endpoint"].split(";") if d.strip()]:
            m = re.fullmatch(r"c([1-9][0-9]*):([SO]\*-(?:time|cost))", d)
            if not m:
                probs.append("%s: endpoint %r is not c<cohort>:<S|O>*-<time|cost>" % (r["rung"], d))
                continue
            if m.group(2) not in ENDPOINTS.get(r["arm"], ()):
                probs.append("%s: endpoint %s on arm %s" % (r["rung"], m.group(2), r["arm"]))
            key = (int(m.group(1)), m.group(2))
            if key in seen:
                probs.append("c%d:%s is declared on %s and %s" % (key[0], key[1], seen[key], r["rung"]))
            seen[key] = r["rung"]
    for c in COHORTS:
        for arm in ("S", "O"):
            for e in ENDPOINTS[arm]:
                if (c, e) not in seen:
                    probs.append("c%d:%s is declared on no rung" % (c, e))
    return probs


def endpoint_rung(rows, cohort, endpoint):
    """The rung declared as ENDPOINT (e.g. S*-time) at COHORT, or None."""
    for r in rows:
        if "c%d:%s" % (cohort, endpoint) in [d.strip() for d in r["endpoint"].split(";")]:
            return r["rung"]
    return None


def source_ok(src, root=ROOT):
    """A resolution's source must be an existing results/... path inside a run or cohort dir (one of
    its directories, below results/, holds manifest.json or cohort.json): '' if so, else why not."""
    src = src.strip()
    if not src.startswith("results/") or ".." in src.split("/"):
        return "source %r is not a results/... path" % src
    full = os.path.join(root, src)
    if not os.path.exists(full):
        return "source %s does not exist" % src
    d = full if os.path.isdir(full) else os.path.dirname(full)
    top = os.path.join(root, "results")
    while os.path.abspath(d).startswith(os.path.abspath(top)) and os.path.abspath(d) != os.path.abspath(top):
        if os.path.exists(os.path.join(d, "manifest.json")) or os.path.exists(os.path.join(d, "cohort.json")):
            return ""
        d = os.path.dirname(d)
    return "source %s is not inside a run or cohort dir (no manifest.json or cohort.json)" % src


SHA_RE = re.compile(r"[0-9a-f]{64}")


def cites_ok(cites, root=ROOT):
    """A resolution's `cites` column (make ladder-select writes it): space-separated `path=sha256`,
    each path a results/... file that exists and hashes to its sha256. '' if every one holds (or
    there are none), else why not."""
    import hashlib
    for c in cites.split():
        p, _, h = c.rpartition("=")
        if not p or not SHA_RE.fullmatch(h):
            return "cite %r is not path=<sha256>" % c
        if not p.startswith("results/") or ".." in p.split("/"):
            return "cite %s is not a results/... path" % p
        full = os.path.join(root, p)
        if not os.path.isfile(full):
            return "cited %s does not exist" % p
        with open(full, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != h:
            return "cited %s has sha256 %s, not the cited %s (changed since the selection)" % (p, got, h)
    return ""


def resolved_rows(path):
    """The rows of ladder.resolved.tsv as dicts, read by the header's column names (origin, cohort,
    key, value, source, and the optional cites, margin and note that make ladder-select writes); a
    file without a header row is read as the first five columns."""
    rows, head = [], ["origin", "cohort", "key", "value", "source"]
    with open(path) as f:
        for l in f:
            if l.startswith("#") or not l.strip():
                continue
            cells = l.rstrip("\n").split("\t")
            if cells[0] == "origin":
                head = cells
                continue
            rows.append(dict(zip(head, cells + [""] * max(0, len(head) - len(cells)))))
    return rows


def read_resolved(path, root=ROOT, rows=None):
    """(origin, cohort, key) -> (value, source); an absent file: no resolutions. Every source must
    pass source_ok, and every cite (the `cites` column) cites_ok; an S4 resolution must give
    THREADS or PROCS as a vcpus ratio (derived per host). With ROWS (the lever table), a row whose
    note names its rule's sha256 (`rule sha256 <hex>`, as make ladder-select writes it) is refused
    when the rung's select rule text no longer hashes to it: the rule changed since the selection."""
    import hashlib
    out = {}
    if not path or not os.path.exists(path):
        return out
    names = by_name(rows) if rows else {}
    for r in resolved_rows(path):
        o, c, k, v, src = (r.get(x, "") for x in ("origin", "cohort", "key", "value", "source"))
        if not src.strip():
            raise ValueError("%s: resolution %s/%s/%s has no source (a results/ path)" % (path, o, c, k))
        why = source_ok(src, root) or cites_ok(r.get("cites", ""), root)
        m = re.search(r"\brule sha256 ([0-9a-f]{64})\b", r.get("note", ""))
        if not why and m and names:
            if o not in names:
                why = "its rung %s is not in the lever table" % o
            elif hashlib.sha256(names[o]["select"].encode()).hexdigest() != m.group(1):
                why = ("its rule sha256 %s is not that of %s's select rule now (%s): the rule changed since the selection"
                       % (m.group(1), o, hashlib.sha256(names[o]["select"].encode()).hexdigest()))
        if why:
            raise ValueError("%s: resolution %s/%s/%s: %s" % (path, o, c, k, why))
        out[(o, c, k)] = (v, src)
    for (o, c, k) in list(out):
        if o == "S4" and k in ("THREADS", "PROCS"):
            t, pr = out.get(("S4", c, "THREADS"), ("", ""))[0], out.get(("S4", c, "PROCS"), ("", ""))[0]
            if not (t.startswith("vcpus") or pr.startswith("vcpus")):
                raise ValueError("%s: S4 at cohort %s: THREADS=%s PROCS=%s; one must be a vcpus ratio, so a host change "
                                 "carries P x T with the vCPUs" % (path, c, t or "?", pr or "?"))
    return out


def token(v, key):
    """A placeholder's (origin, key) lookup: @probe-tune is S3's HOST_TUNES; @select:R[:KEY]."""
    if v == "@probe-tune":
        return ("S3", "HOST_TUNES")
    m = re.fullmatch(r"@select:([A-Za-z0-9-]+)(?::([A-Z_]+|instance))?", v)
    if m:
        return (m.group(1), m.group(2) or key)
    return None


def notrun_decl(row, cohort):
    """(reason, conditional?) of ROW's not_run_cohorts entry at COHORT, or ('', False). An entry
    ending in COND (`c<C>: <reason> (if same configuration)`) is conditional: the rung is not run
    there exactly where it resolves to its run predecessor's configuration (notrun_state)."""
    for d in [d.strip() for d in row.get("not_run_cohorts", "").split(";") if d.strip()]:
        if d.split(":", 1)[0] == "c%s" % cohort:
            why = d.split(":", 1)[1]
            return (why[:-len(COND)], True) if why.endswith(COND) else (why, False)
    return "", False


def notrun_state(rows, row, cohort, res, depth=0):
    """(state, why) of ROW's conditional not_run_cohorts entry at COHORT under RES: ('none', '')
    without one; ('not-run', why) where the rung and its run predecessor resolve to one configuration
    (the selection upstream left it nothing to change: O1 where S8 keeps K = 1); ('run', why) where
    they resolve and differ; ('undecided', why) while either is unresolved."""
    why, cond = notrun_decl(row, cohort)
    if not cond:
        return "none", ""
    p = run_pred_at(rows, row, cohort, res)
    if p is None:
        return "undecided", "no run predecessor"
    if p["status"].startswith("alias:") or alias_state(rows, p, cohort, res, depth + 1)[0] != "none":
        p = config_row(rows, p, cohort, res) or p
    a, abad = _values(rows, row, cohort, res, depth + 1)
    b, bbad = _values(rows, p, cohort, res, depth + 1)
    if abad or bbad:
        return "undecided", "unresolved: %s" % ", ".join(["%s %s" % (row["rung"], x) for x in abad] +
                                                         ["%s %s" % (p["rung"], x) for x in bbad])
    if same_config(a, b):
        return "not-run", "not-run at c%s:%s (conditional: it resolves to %s's configuration)" % (cohort, why, p["rung"])
    return "run", "configurations differ from %s's in %s" % (
        p["rung"], ",".join(k for k in KEYS + ["instance"] if not same_value(k, a[k], a["instance"], b[k], b["instance"])))


def not_run_at(row, cohort, rows=None, res=None):
    """'' if the row runs at COHORT, else why not (status not-run, or a not_run_cohorts entry). A
    conditional entry counts only with ROWS and RES given, and only where it holds (notrun_state)."""
    if row["status"].startswith("not-run"):
        return row["status"]
    why, cond = notrun_decl(row, cohort)
    if not why and not cond:
        return ""
    if not cond:
        return "not-run at c%s:%s" % (cohort, why)
    if rows is None or res is None:
        return ""
    st, w = notrun_state(rows, row, cohort, res)
    return w if st == "not-run" else ""


def run_pred_at(rows, row, cohort, res=None):
    """The nearest predecessor that runs at COHORT (not-run ones are skipped; with RES, conditional
    not_run_cohorts entries that hold too), or None."""
    p, seen = pred_of(rows, row), set()
    while p is not None and not_run_at(p, cohort, rows if res is not None else None, res) and p["rung"] not in seen:
        seen.add(p["rung"])
        p = pred_of(rows, p)
    return p


def vcpus_of(itype):
    """vCPUs of an instance type from its size (Graviton: xlarge = 4 vCPUs): None if unknown."""
    m = re.fullmatch(r"[a-z0-9-]+\.(?:(\d*)xlarge|(large)|(medium))", itype or "")
    if not m:
        return None
    if m.group(2):
        return 2
    if m.group(3):
        return 1
    return 4 * int(m.group(1) or 1)


VC_KEYS = ("THREADS", "PROCS", "INFLIGHT")


def same_value(k, a, ahost, b, bhost):
    """Whether key K is unchanged between value A on host AHOST and B on BHOST: the same text (a
    vcpus-derived move with the host is the host's lever, listed in `derived`), or, for THREADS,
    PROCS and INFLIGHT, the same number once vcpus forms are resolved with vc() at each one's host."""
    if a == b:
        return True
    if k in VC_KEYS and a != "-" and b != "-":
        va, vb = vcpus_of(ahost), vcpus_of(bhost)
        if va and vb:
            try:
                return vc(a, va) == vc(b, vb)
            except ValueError:
                return False
    return False


def alias_winner(rows, o, cohort, res):
    """The winner of alias rung O at COHORT from RES, or None; ValueError if it is not one of its alias_of."""
    a = res.get((o["rung"], str(cohort), "alias"))
    if not a:
        return None
    cands = [c for c in o["alias_of"].split("|") if c]
    if a[0] not in cands:
        raise ValueError("alias %s at cohort %s: winner %s is not one of its alias_of (%s)"
                         % (o["rung"], cohort, a[0], ", ".join(cands)))
    w = by_name(rows).get(a[0])
    if w is not None and a[0] != o["predecessor"] and not_run_at(w, cohort):
        raise ValueError("alias %s at cohort %s: winner %s is not a candidate there (%s)" % (o["rung"], cohort, a[0], not_run_at(w, cohort)))
    return a


def config_row(rows, row, cohort, res, seen=None):
    """The rung whose runs give ROW's configuration at COHORT: ROW itself or, following each in turn,
    its run predecessor if it is not run there, its alias_cohorts target (a conditional entry where
    it holds), or its alias winner (RES). None if an alias on the way is unresolved or undecided."""
    names, seen = by_name(rows), seen or []
    if row is None or row["rung"] in seen:
        return None
    seen = seen + [row["rung"]]
    if not_run_at(row, cohort, rows, res):
        return config_row(rows, run_pred_at(rows, row, cohort, res), cohort, res, seen)
    st, t, _ = alias_state(rows, row, cohort, res)
    if st == "undecided":
        return None
    if st == "alias":
        return config_row(rows, names.get(t), cohort, res, seen)
    if row["status"].startswith("alias:"):
        a = alias_winner(rows, row, cohort, res)
        return config_row(rows, names.get(a[0]), cohort, res, seen) if a else None
    return row


def _values(rows, r, cohort, res, depth=0):
    """Every PARAM and the instance of row r at cohort under resolutions res: (values, unresolved).
    A token @select:<origin>[:KEY] resolves, in this order: an origin not run at the cohort to its
    run predecessor's value; an origin aliased there (alias_cohorts; a conditional entry where it
    holds, unresolved while it is undecided) to its target's; an alias origin
    (status alias) to its winner's value of that key, the winner named in res; any other origin to
    res's (origin, cohort, KEY) row."""
    if depth > 40:
        raise ValueError("%s: the @select tokens form a loop" % r["rung"])
    names = by_name(rows)
    bad, out = [], {}
    for k in KEYS + ["instance"]:
        v = instance_of(rows, r) if k == "instance" else r[k]
        if k == "instance" and v.startswith("@floor:"):
            # The family of <origin>'s resolved host; this rung's host is that family's smallest
            # type that holds it at this cohort (fits(), with every other PARAM as resolved here).
            o = names.get(v[len("@floor:"):])
            ov = _values(rows, o, cohort, res, depth + 1)[0] if o is not None else {}
            if bad or "instance" not in ov:
                bad.append("instance=%s (%s)" % (v, "its own values are unresolved" if bad else "its origin's host is unresolved"))
                continue
            fam = ov["instance"].split(".")[0]
            t, why = floor_type(FLOOR_FAMILY.get(fam, fam), out, cohort)
            if t is None:
                bad.append("instance=%s (%s)" % (v, why))
                continue
            out[k] = t
            continue
        if k == "instance" and FIT_RE.fullmatch(v):
            # O2's candidate of one family: its smallest type that holds the rung at this cohort.
            if bad:
                bad.append("instance=%s (its own values are unresolved)" % v)
                continue
            t, why = floor_type(FIT_RE.fullmatch(v).group(1), out, cohort)
            if t is None:
                bad.append("instance=%s (%s)" % (v, why))
                continue
            out[k] = t
            continue
        if RATIO_RE.fullmatch(v):
            # The O arm's thread ratio (ruling 1): R = the origin's vCPUs / its THREADS at its host.
            m = RATIO_RE.fullmatch(v)
            o = names.get(m.group(1))
            ov, obad = _values(rows, o, cohort, res, depth + 1) if o is not None else ({}, ["no rung %s" % m.group(1)])
            hv = vcpus_of(ov.get("instance", ""))
            if obad or not hv:
                bad.append("%s=%s (%s)" % (k, v, "its origin %s is unresolved: %s" % (m.group(1), ", ".join(obad)) if obad
                                           else "no vCPUs for %s" % ov.get("instance")))
                continue
            t = vc(ov["THREADS"], hv)
            if hv % t:
                bad.append("%s=%s (%s's THREADS %d does not divide its %d vCPUs: no integer ratio)" % (k, v, o["rung"], t, hv))
                continue
            ratio = hv // t
            # The engine's in flight is clamped to the cohort (fill/R/C): no host plans, or is sized for,
            # more samples at once than the cohort has. PROCS is not, so O0 stays S*'s exact PROCS (the
            # S arm's P = vcpus/T may exceed the cohort: lanes without samples).
            if m.group(2):
                out[k] = "1" if ratio == 1 else ("fill/%d/%d" % (ratio, int(cohort)) if k == "INFLIGHT" else "fill/%d" % ratio)
            else:
                out[k] = "vcpus" if ratio == 1 else "vcpus/%d" % ratio
            continue
        if v.startswith("@"):
            t = token(v, k)
            hit = None
            if t:
                o = names.get(t[0])
                src, how = None, ""
                if o is not None and not_run_at(o, cohort):
                    # Not run at this cohort: its selection has one candidate, its predecessor's value.
                    src = run_pred_at(rows, o, cohort)
                    how = "not run at c%s: %s's value" % (cohort, src["rung"] if src else "-")
                elif o is not None and alias_at(o, cohort) and alias_state(rows, o, cohort, res, depth + 1)[0] != "own":
                    # An alias there (or a conditional entry not yet decided: unresolved, not guessed).
                    ast, at, _ = alias_state(rows, o, cohort, res, depth + 1)
                    if ast == "alias":
                        src, how = names.get(at), "alias at c%s of %s" % (cohort, at)
                elif o is not None and o["status"].startswith("alias:"):
                    a = alias_winner(rows, o, cohort, res)   # the alias's winner, then its value of the key
                    if a:
                        src, how = names[a[0]], a[1]
                else:
                    hit = res.get((t[0], str(cohort), t[1]))
                if src is not None:
                    if src is o:
                        raise ValueError("%s: %s at cohort %s resolves to itself" % (r["rung"], o["rung"], cohort))
                    sv, _ = _values(rows, src, cohort, res, depth + 1)
                    if t[1] in sv:
                        hit = (sv[t[1]], how)
            if hit is None:
                bad.append("%s=%s" % (k, v))
                continue
            v = hit[0]
        if not SAFE.match(v) and not re.fullmatch(r"vcpus/[1-9][0-9]*", v) and not FILL_RE.fullmatch(v):
            bad.append("%s=%s (not a shell-safe word)" % (k, v))
        out[k] = v
    return out, bad


_FILE_CACHE = {}


def _cached(path, parse):
    """PARSE(path), kept while the file's mtime and size are unchanged (make ladder-advance's plan
    resolves many hypothetical selections)."""
    st = os.stat(path)
    key = (parse.__name__, os.path.abspath(path))
    hit = _FILE_CACHE.get(key)
    if hit is None or hit[0] != (st.st_mtime_ns, st.st_size):
        hit = ((st.st_mtime_ns, st.st_size), parse(path))
        _FILE_CACHE[key] = hit
    return hit[1]


def load_types(path=None):
    """type -> (vcpus, memory_mib) from scripts/g3/ladder.types.tsv (the families O2 and O3 choose among)."""
    return dict(_cached(path or TYPES, _parse_types))


def _parse_types(path):
    out = {}
    with open(path) as f:
        head = None
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            c = line.rstrip("\n").split("\t")
            if head is None:
                head = c
                continue
            d = dict(zip(head, c))
            out[d["type"]] = (int(d["vcpus"]), int(d["memory_mib"]))
    return out


def floor_type(family, params, cohort, types=None):
    """(the smallest non-metal type of FAMILY that holds a rung with PARAMS at COHORT by fits(), with
    every vcpus form resolved at that type, or None, why). Smallest: by memory, then vCPUs."""
    types = load_types() if types is None else types
    cands = sorted(((m, v, t) for t, (v, m) in types.items() if t.split(".")[0] == family and "metal" not in t))
    if not cands:
        return None, "no %s types in %s" % (family, os.path.relpath(TYPES, ROOT))
    for m, v, t in cands:
        try:
            if not fits({"params": params, "instance": t}, int(cohort), m, v):
                return t, ""
        except (ValueError, KeyError) as e:
            return None, "fits() cannot judge %s: %s" % (t, e)
    return None, "no %s type holds it at c%s (the largest, %s, does not)" % (family, cohort, cands[-1][2])


def same_config(a, b):
    """Two _values results describe one configuration (vcpus forms compared at each one's host)."""
    if a["instance"] != b["instance"]:
        return False
    return all(same_value(k, a[k], a["instance"], b[k], b["instance"]) for k in KEYS)


def time_counterpart(rows, rung):
    """The time-chain rung of a cost-chain rung (its name without '-cost'), or None."""
    if "-cost" not in rung:
        return None
    t = rung.replace("-cost", "", 1)
    return t if t in by_name(rows) else None


def alias_cohort_problems(rows, cohort, res):
    """Each unconditional alias_cohorts declaration at COHORT must name a rung whose resolved
    configuration equals the declaring rung's. One that cannot be resolved yet is not a problem here
    (the generator refuses either rung until it is). A conditional one (`... (if same configuration)`)
    is never false: it is an alias where the two coincide and an ordinary rung where they differ."""
    names, out = by_name(rows), []
    for r in rows:
        t, cond = alias_decl(r, cohort)
        if not t or cond or t not in names:
            continue
        a, abad = _values(rows, r, cohort, res)
        b, bbad = _values(rows, names[t], cohort, res)
        if abad or bbad:
            continue
        if not same_config(a, b):
            diff = [k for k in KEYS + ["instance"] if a[k] != b[k]]
            out.append("%s at c%s is declared an alias of %s (alias_cohorts), but their configurations differ in %s"
                       % (r["rung"], cohort, t, ",".join(diff)))
    return out


def bracket(rows, alias_row, cohort, res, root=ROOT):
    """For an alias whose select rule has a `bracket:` clause on the #26 fit ("... within a factor 2
    of fit <F>'s time|cost-optimal N over {1, 2, ...}, each N on its own type, ... widened to every
    candidate where that prediction is not within data or a type has none"): (the candidate names
    inside the bracket at COHORT, how, [cited files]). None if the rule has no bracket. Each
    candidate is predicted on its own resolved host (O3-n<K>: its family's smallest type that holds
    table/K), and the grid must be the candidates' N (the predecessor's own N may be 1 and absent
    from the rows). Raises Unresolved while a candidate is unresolved or the grid is not the candidates'."""
    m = re.search(r"bracket: .*?fit (\S+)'s (time|cost)-optimal N over \{([0-9, ]+)\}", alias_row["select"])
    if not m:
        return None
    fit, obj, grid = m.group(1), m.group(2), {int(x) for x in m.group(3).split(",")}
    names = by_name(rows)
    cands = [c for c in alias_row["alias_of"].split("|") if c]
    vals = {}
    for c in cands:
        v, bad = _values(rows, names[c], cohort, res)
        if bad:
            raise Unresolved("%s at c%s: candidate %s is unresolved (%s), so its bracket cannot be computed"
                             % (alias_row["rung"], cohort, c, ", ".join(bad)))
        vals[c] = v
    rowns = {int(names[c]["SHARDS"]) for c in cands if re.fullmatch(r"[0-9]+", names[c]["SHARDS"])}
    if not rowns <= grid or not grid - rowns <= {1}:
        raise Unresolved("%s: the bracket's grid {%s} is not its candidate rows' N {%s} (plus the predecessor's 1)"
                         % (alias_row["rung"], ", ".join(map(str, sorted(grid))), ", ".join(map(str, sorted(rowns)))))
    path = os.path.join("results", "g3", "fit26", "predictions.tsv")
    full = os.path.join(root, path)
    pred = {}
    if os.path.isfile(full):
        import csv
        with open(full) as f:
            for p in csv.DictReader(f, delimiter="\t"):
                if p["fit"] == fit and p["cohort"] == str(cohort):
                    pred[(p["type"], int(p["N"]))] = (float(p["T_pred_s"] if obj == "time" else p["usd_run_NpT"]), p["status"])
    cited = [path] if os.path.isfile(full) else []
    on = {c: (vals[c]["instance"], int(vals[c]["SHARDS"])) for c in cands}
    missing = sorted("%s at N=%d" % tn for c, tn in on.items() if tn not in pred and tn[1] in grid)
    if missing:
        return set(cands), "widened: fit %s has no %s prediction at c%s for %s" % (fit, obj, cohort, ", ".join(missing)), cited
    best = min((pred[tn][0], tn[1], tn[0], pred[tn][1]) for tn in on.values() if tn[1] in grid)
    if best[3] != "within data":
        return set(cands), "widened: fit %s's %s-optimal N at c%s is %d on %s, %s" % (fit, obj, cohort, best[1], best[2], best[3]), cited
    inside = {c for c in cands if best[1] / 2 <= on[c][1] <= 2 * best[1]}
    return inside, "fit %s's %s-optimal N at c%s is %d on %s (within data): N in [%g, %d]" % (
        fit, obj, cohort, best[1], best[2], best[1] / 2, 2 * best[1]), cited


RANGE_RE = re.compile(r"(?:^|; )range: INFLIGHT 1 \.\. vCPUs / THREADS at the predecessor's host")


def inflight_range(rows, alias_row, cohort, res, types=None):
    """For an alias whose select rule has the in-flight `range:` clause (O4b, O4b-cost): ({candidate:
    why it is left out}, how) at COHORT, every other alias_of candidate being in range. The bound is
    max(1, vCPUs // THREADS) at the predecessor's resolved host (O4a's: O3's winning type), with
    THREADS as resolved there. A candidate is left out when its INFLIGHT is above the bound, equal to
    the predecessor's own INFLIGHT (the predecessor itself), or (memory permitting) does not fit the
    host by fits(). None if the rule has no range clause. Raises Unresolved while the predecessor is
    unresolved (the bound needs its host and THREADS)."""
    if not RANGE_RE.search(alias_row.get("select", "")):
        return None
    names = by_name(rows)
    p = names.get(alias_row["predecessor"])
    if p is None:
        raise Unresolved("%s: its predecessor %s is not in the table" % (alias_row["rung"], alias_row["predecessor"]))
    pv, bad = _values(rows, p, cohort, res)
    if bad:
        raise Unresolved("%s at c%s: its predecessor %s is unresolved (%s), so its in-flight range cannot be computed"
                         % (alias_row["rung"], cohort, p["rung"], ", ".join(bad)))
    v = vcpus_of(pv["instance"])
    if not v:
        raise Unresolved("%s at c%s: no vCPUs for the predecessor's host %s" % (alias_row["rung"], cohort, pv["instance"]))
    t = vc(pv["THREADS"], v)
    bound = max(1, v // t)
    pk = 1 if pv["INFLIGHT"] == "-" else vc(pv["INFLIGHT"], v)
    types = load_types() if types is None else types
    mem = types.get(pv["instance"], (None, None))[1]
    out = {}
    for c in [c for c in alias_row["alias_of"].split("|") if c and c != alias_row["predecessor"]]:
        cv, cbad = _values(rows, names[c], cohort, res)
        if cbad:
            raise Unresolved("%s at c%s: candidate %s is unresolved (%s)" % (alias_row["rung"], cohort, c, ", ".join(cbad)))
        k = vc(cv["INFLIGHT"], vcpus_of(cv["instance"]) or v)
        if k > bound:
            out[c] = "INFLIGHT %d > vCPUs / THREADS = %d // %d = %d on %s" % (k, v, t, bound, pv["instance"])
        elif k == pk:
            out[c] = "INFLIGHT %d is %s's own (%s on %s)" % (k, p["rung"], pv["INFLIGHT"], pv["instance"])
        elif k > pk and mem is not None:
            pr = fits({"params": cv, "instance": cv["instance"]}, int(cohort), mem, v)
            if pr:
                out[c] = "memory: " + "; ".join(pr)
    how = ("INFLIGHT 1 .. %d (vCPUs / THREADS = %d // %d on %s, %s's host); %s's own INFLIGHT is %d"
           % (bound, v, t, pv["instance"], p["rung"], p["rung"], pk))
    return out, how


def group_keys(group):
    """The PARAMs (and 'instance' for HOST) of a key-group."""
    return ["instance"] if group == "HOST" else group.split("+")


def candidate_out(rows, rung, cohort, res, root=ROOT):
    """'' if RUNG, a candidate of an alias, is a candidate there at COHORT under RES, else why not:
      - it is outside the alias's bracket (O3's N around the #26 fit);
      - it is outside the alias's in-flight range (O4b's INFLIGHT 1 .. vCPUs / THREADS);
      - its value of the alias's group is the predecessor's own (as resolved at each one's host): it
        is the predecessor itself there, which the alias already counts (O2-x8g on O1's own type,
        O3-n<K> at O2's own N, where the candidate would change only the host, O2's lever).
    '' too for a rung that is no alias's candidate. Raises Unresolved while the alias's bracket or
    range cannot be computed."""
    names = by_name(rows)
    al = candidates_of(rows).get(rung)
    if al is None or rung == names[al]["predecessor"]:
        return ""
    a = names[al]
    b = bracket(rows, a, cohort, res, root)
    if b is not None and rung not in b[0]:
        return "outside %s's bracket (%s)" % (al, b[1])
    rg = inflight_range(rows, a, cohort, res)
    if rg is not None and rung in rg[0]:
        return "outside %s's range (%s; %s)" % (al, rg[0][rung], rg[1])
    p = names.get(a["predecessor"])
    if p is None:
        return ""
    if not_run_at(p, cohort, rows, res) or p["status"].startswith("alias:") or alias_state(rows, p, cohort, res)[0] != "none":
        p = config_row(rows, p, cohort, res) or p
    cv, cbad = _values(rows, names[rung], cohort, res)
    pv, pbad = _values(rows, p, cohort, res)
    if cbad or pbad:
        return ""
    keys = group_keys(a["group"])
    if all(cv[k] == pv[k] if k == "instance" else same_value(k, cv[k], cv["instance"], pv[k], pv["instance"]) for k in keys):
        return ("outside %s's candidates (its %s is that of %s%s: %s; it is that predecessor there)"
                % (al, "+".join(keys), a["predecessor"], "" if p["rung"] == a["predecessor"] else " (%s's runs)" % p["rung"],
                   ", ".join("%s=%s" % (k, cv[k]) for k in keys)))
    return ""


def notrun_resolution_warnings(rows, res):
    """Warnings for resolution rows given for a rung at a cohort where it is not run: at such a
    cohort its tokens resolve to its predecessor's values, so the row is never used."""
    names, out = by_name(rows), []
    for (o, c, k), (v, src) in sorted(res.items()):
        r = names.get(o)
        if r is not None and not_run_at(r, c):
            out.append("ladder.resolved.tsv: %s at c%s (%s=%s, from %s) is ignored: %s" % (o, c, k, v, src, not_run_at(r, c)))
    return out


def resolve(rows, rung, cohort, resolved=None, root=ROOT, res=None):
    """{'params': {K: v}, 'instance', 'az', 'ttl_c1', 'arm', 'want_n'}; raises Unresolved. After
    resolving, the one-lever rule is checked again on the resolved values against the resolved
    predecessor (an alias predecessor is its winner, a not-run one is skipped): a resolution that
    makes the rung identical to its predecessor, or changes another key-group, is refused. RES, when
    given, is the resolutions themselves ((origin, cohort, key) -> (value, source)), in place of the
    file RESOLVED: make ladder-advance's plan resolves under hypothetical selections this way."""
    names = by_name(rows)
    if rung not in names:
        raise KeyError("no rung %s in the table" % rung)
    r = names[rung]
    why = not_run_at(r, cohort)
    if why:
        raise Unresolved("%s is %s: no spec is generated for it" % (rung, why))
    if r["status"] != "run":
        raise Unresolved("%s is %s: no spec is generated for it" % (rung, r["status"]))
    if res is None:
        res = read_resolved(resolved, root, rows) if resolved is not None else {}
    # A conditional not_run_cohorts entry: not run where the selections upstream leave it its run
    # predecessor's configuration (O1 where S8 keeps K = 1), refused while that is undecided.
    nst, nwhy = notrun_state(rows, r, cohort, res)
    if nst == "not-run":
        raise Unresolved("%s is %s: no spec is generated for it" % (rung, nwhy))
    if nst == "undecided":
        raise Unresolved("%s at c%s: its conditional not_run_cohorts entry is undecided (%s): it is generated only once it "
                         "resolves and differs from its predecessor" % (rung, cohort, nwhy))
    st, at, why = alias_state(rows, r, cohort, res, root=root)
    if st == "alias":
        raise Unresolved("%s is alias: same configuration as %s at c%s (alias_cohorts%s): no spec is generated for it; "
                         "%s's runs are read" % (rung, at, cohort, ", conditional: it holds" if alias_decl(r, cohort)[1] else "", at))
    if st == "undecided":
        raise Unresolved("%s at c%s: its conditional alias_cohorts entry (%s%s) is undecided (%s): it is generated "
                         "only once both resolve and differ" % (rung, cohort, at, COND, why))
    probs = alias_cohort_problems(rows, cohort, res)
    if probs:
        raise Unresolved("; ".join(probs))
    out, bad = _values(rows, r, cohort, res)
    if bad:
        raise Unresolved("%s at cohort %s has unresolved values: %s" % (rung, cohort, ", ".join(bad)))
    # The cost chain reads the time chain where the two coincide (alias_cohorts), so a cost rung
    # equal to its time counterpart must be declared there, not run twice. A counterpart that is no
    # candidate there has no runs to read, so it needs no declaration.
    tc = time_counterpart(rows, rung)
    if (st == "none" and tc is not None and names[tc]["status"] == "run" and not not_run_at(names[tc], cohort, rows, res)
            and alias_state(rows, names[tc], cohort, res)[0] == "none"):
        tv, tbad = _values(rows, names[tc], cohort, res)
        try:
            tout = candidate_out(rows, tc, cohort, res, root) if not tbad and same_config(dict(out), tv) else ""
        except Unresolved:
            tout = ""   # its candidacy cannot be judged: the coincidence still needs its declaration
        if not tbad and not tout and same_config(dict(out), tv):
            raise Unresolved("%s at cohort %s has the configuration of its time counterpart %s: declare alias_cohorts "
                             "'c%s: %s' (it reads %s's runs) instead of running it, or 'c%s: %s%s' where the "
                             "coincidence depends on a selection" % (rung, cohort, tc, cohort, tc, tc, cohort, tc, COND))
    # A candidate outside its alias's bracket (O3's N around the #26 fit) or in-flight range (O4b's
    # INFLIGHT 1 .. vCPUs / THREADS), or one that is its alias's predecessor's own configuration in the
    # alias's group (O2-x8g on O1's type, O3-n<K> at O2's N), is not run.
    co = candidate_out(rows, rung, cohort, res, root)
    if co:
        raise Unresolved("%s at cohort %s is %s: not a candidate there" % (rung, cohort, co))
    p = run_pred_at(rows, r, cohort, res)
    if p is not None and (p["status"].startswith("alias:") or alias_state(rows, p, cohort, res)[0] != "none"):
        p = config_row(rows, p, cohort, res) or p
    if p is not None:
        pv, pbad = _values(rows, p, cohort, res)
        if pbad:
            raise Unresolved("%s at cohort %s: its predecessor %s is unresolved (%s), so the one-lever check cannot run"
                             % (rung, cohort, p["rung"], ", ".join(pbad)))
        ch = [k for k in KEYS if not same_value(k, out[k], out["instance"], pv[k], pv["instance"])]
        if out["instance"] != pv["instance"]:
            ch.append("instance")
        free = [k for k in ch if k not in coupled_keys(r) and not (k == "instance" and derived_host(rows, r))]
        groups = sorted({GROUP[k] for k in free})
        if not ch:
            raise Unresolved("%s at cohort %s: the resolution makes it identical to %s (mark it not-run instead)"
                             % (rung, cohort, p["rung"]))
        if groups != [r["group"]]:
            raise Unresolved("%s at cohort %s: resolved, it changes %s against %s, not just the group %s"
                             % (rung, cohort, ",".join(ch), p["rung"], r["group"]))
    inst = out.pop("instance")
    # Ours never oversubscribes (ruling 1): THREADS x the samples at once (PROCS, or INFLIGHT on the
    # engine) is at most the host's vCPUs.
    hv = vcpus_of(inst)
    if r["arm"] == "O" and hv:
        w = out["INFLIGHT"] if out["CLASSIFIER"] == "ours-engine" else out["PROCS"]
        t, k = vc(out["THREADS"], hv), (1 if w == "-" else vc(w, hv))
        if t * k > hv:
            raise Unresolved("%s at cohort %s oversubscribes %s: THREADS %s (%d) x %d at once = %d > %d vCPUs"
                             % (rung, cohort, inst, out["THREADS"], t, k, t * k, hv))
    # fill/R has no form in the body: the value at the rung's own pinned type.
    for key in VC_KEYS:
        if FILL_RE.fullmatch(out[key]):
            if not hv:
                raise Unresolved("%s at cohort %s: %s=%s needs the vCPUs of %s" % (rung, cohort, key, out[key], inst))
            out[key] = str(vc(out[key], hv))
    want = int(out["REPLICAS"]) * int(out["SHARDS"])
    return {"params": out, "instance": inst, "az": r["az"], "ttl_c1": r["ttl_min_c1"], "arm": r["arm"], "want_n": want}


def _parse_runs(path):
    rows = []
    with open(path) as f:
        head = f.readline().rstrip("\n").split("\t")
        for l in f:
            d = dict(zip(head, l.rstrip("\n").split("\t")))
            rows.append((int(d["rank"]), d["run"], int(d["read_count"]), int(d["bytes_1"]) + int(d["bytes_2"])))
    return rows


def cohort_runs(cohort, path=RUNS):
    rows = [(r, w, b) for k, r, w, b in _cached(path, _parse_runs) if k <= cohort]
    if len(rows) != cohort:
        raise ValueError("runs.tsv has %d of ranks 1-%d" % (len(rows), cohort))
    return rows


def assign(weights, k, mode):
    """Bin of each item (mod: j mod k; lpt: heaviest first, ties in order, to the least-loaded bin,
    ties to the lowest), as the body's lad_assign and cmd/aws-kraken2/place.go do."""
    if mode == "mod":
        return [j % k for j in range(len(weights))]
    load, out = [0] * k, [0] * len(weights)
    for j in sorted(range(len(weights)), key=lambda j: (-weights[j], j)):
        b = min(range(k), key=lambda i: (load[i], i))
        out[j] = b
        load[b] += weights[j]
    return out


def vc(v, vcpus):
    """A PARAM value with vcpus or vcpus/<k> resolved for a host of VCPUS (at least 1), as the body does."""
    if v == "vcpus":
        return vcpus
    if v.startswith("vcpus/"):
        return max(1, vcpus // int(v[6:]))
    m = FILL_RE.fullmatch(v)
    if m:
        # fill/R: the samples at once that THREADS = vcpus/R leaves room for (P x T <= vCPUs);
        # fill/R/C: no more than the cohort's C samples (a host never plans more in flight than exist).
        n = vcpus // max(1, vcpus // int(m.group(1)))
        return min(n, int(m.group(2))) if m.group(2) else n
    return int(v)


def fits(res, cohort, mem_mib, vcpus=96):
    """Memory and NVMe needs of the busiest node; a list of problems (empty: it fits)."""
    p = res["params"]
    runs = cohort_runs(cohort)
    rep, sh = int(p["REPLICAS"]), int(p["SHARDS"])
    grp = assign([w for _, w, _ in runs], rep, p["PLACEMENT"])
    gb = [sum(b for (_, _, b), g in zip(runs, grp) if g == i) for i in range(rep)]
    gp = [sum(w for (_, w, _), g in zip(runs, grp) if g == i) for i in range(rep)]
    i = max(range(rep), key=lambda i: gb[i])
    inb, pairs = gb[i], gp[i]
    if sh > 1:
        inb = inb // sh + max(b for _, _, b in runs)
        pairs = pairs // sh + max(w for _, w, _ in runs)
    outb = 0 if p["OUT_UPLOAD"] == "sdk-stream" else pairs * OUT_BYTES_PER_PAIR
    ram, nvme, why = OS_SLACK, 0, []
    if p["DB_PLACE"] == "memory":
        inflight = vc(p["INFLIGHT"], vcpus) if p["INFLIGHT"] != "-" else 1
        ram += int(1.15 * HASH_BYTES / sh) + 8 * 10 ** 9 + int(7.5 * 10 ** 9) * inflight
        why.append("engine shard 1/%d x 1.15 + 8 GB + 7.5 GB x %d in flight (scripts/g3/mkspec.sh's rule)" % (sh, inflight))
    elif p["DB_PLACE"] in ("tmpfs", "tmpfs-huge"):
        ram += HASH_BYTES
        why.append("hash.k2d on tmpfs")
    else:
        nvme += HASH_BYTES
        if p["DB_LOAD"] == "load":
            ram += HASH_BYTES
            why.append("hash.k2d read into the process")
    if p["IN_DEST"] == "tmpfs":
        ram += inb + outb
        why.append("inputs %.1f GB + outputs %.1f GB on tmpfs" % (inb / 1e9, outb / 1e9))
    else:
        nvme += inb + outb
    probs = []
    have = mem_mib * 1048576
    if ram > have:
        probs.append("%s needs %.0f GiB of memory (%s; %d GiB OS slack), has %d GiB" % (
            res["instance"], ram / 2 ** 30, "; ".join(why), OS_SLACK >> 30, have >> 30))
    if nvme:
        cap = NVME_BYTES.get(res["instance"])
        if cap is None:
            probs.append("%s: DB_PLACE or IN_DEST is nvme, and this type has no known instance-store device" % res["instance"])
        elif nvme > 0.95 * cap:
            probs.append("%s: %.0f GB on one NVMe device of %.0f GB" % (res["instance"], nvme / 1e9, cap / 1e9))
    return probs


def spec_params(spec):
    """manifest.json / cohort.json `params` for a ladder spec (#52's contract), from the PARAMS block
    mkspec-ladder.sh wrote into command[2]; None for any other spec. Keys lowercased; cohort, want_n,
    replicas, shards and rep as ints; run_kind ladder and state cold (every ladder run is cold)."""
    try:
        body = spec["command"][2]
    except (KeyError, IndexError, TypeError):
        return None
    lines = body.split("\n")
    for i, l in enumerate(lines):
        if l.startswith(PARAMS_MARK) and i + 1 < len(lines):
            out = collections.OrderedDict()
            for kv in lines[i + 1].split(";"):
                kv = kv.strip()
                if "=" not in kv:
                    continue
                k, v = kv.split("=", 1)
                k = k.strip().lower()
                if k in ("cohort", "want_n", "replicas", "shards", "rep") and re.fullmatch(r"[0-9]+", v):
                    v = int(v)
                out[k] = v
            if "rung" not in out:
                return None
            out.setdefault("run_kind", "ladder")
            out.setdefault("state", "cold")
            out["source"] = "spec command[2] PARAMS block"
            return dict(out)
    return None


def spec_params_rep(spec, rep):
    """spec_params with the launch's replicate number (AK2_LADDER_REP): rep and rep_source added.
    Refuses (ValueError) a non-ladder spec, a rep that is not an integer >= 1, and a PARAMS block
    that already names another REP. The spec's bytes are the same for every rep."""
    p = spec_params(spec)
    if p is None:
        raise ValueError("AK2_LADDER_REP is set, but the spec has no ladder PARAMS block")
    if not re.fullmatch(r"[1-9][0-9]*", str(rep)):
        raise ValueError("AK2_LADDER_REP %r is not an integer >= 1" % (rep,))
    rep = int(rep)
    if "rep" in p and p["rep"] != rep:
        raise ValueError("AK2_LADDER_REP %d, but the spec's PARAMS block says REP=%s" % (rep, p["rep"]))
    p["rep"] = rep
    p["rep_source"] = REP_SOURCE
    return p


def az_rows(path=AZS):
    """The AZ list's rows in file order (the order is the preference order for a retry)."""
    if not os.path.isfile(path):
        return []
    out = []
    with open(path) as f:
        hdr = None
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cells = line.split("\t")
            if hdr is None:
                hdr = cells
                continue
            out.append(dict(zip(hdr, cells)))
    return out


def az_alt(itype, az, path=AZS, root=ROOT, tracked=True):
    """The documented-AZ row for (itype, az) in scripts/g3/ladder.azs.tsv (columns type, az,
    evidence), with its evidence checked: a committed (git-tracked) manifest under results/ whose
    instance.type and instance.az are exactly these. Raises ValueError otherwise."""
    for r in az_rows(path):
        if r.get("type") == itype and r.get("az") == az:
            ev = r.get("evidence", "")
            full = os.path.normpath(os.path.join(root, ev))
            if not ev.startswith("results/") or not ev.endswith("/manifest.json") or not os.path.isfile(full):
                raise ValueError("%s %s: evidence %s is not a manifest under results/" % (itype, az, ev))
            if tracked:
                import subprocess
                g = subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", ev], capture_output=True)
                if g.returncode != 0:
                    raise ValueError("%s %s: evidence %s is not committed (git ls-files)" % (itype, az, ev))
            with open(full) as f:
                inst = (json.load(f).get("instance") or {})
            if inst.get("type") != itype or inst.get("az") != az:
                raise ValueError("%s %s: evidence %s records %s in %s" % (itype, az, ev, inst.get("type"), inst.get("az")))
            return {"type": itype, "az": az, "evidence": ev, "list": os.path.relpath(path, root)}
    raise ValueError("%s in %s is not in %s" % (itype, az, os.path.relpath(path, root)))


def _params_main(a):
    tsv, resd, mem, vcpus = TSV, RESOLVED, None, 96
    rung, cohort = a[0], a[1]
    rest = a[2:]
    while rest:
        if len(rest) < 2:
            raise SystemExit("ladder_levers: flag %s needs a value" % rest[0])
        f, v = rest[0], rest[1]
        rest = rest[2:]
        if f == "--tsv":
            tsv = v
        elif f == "--resolved":
            resd = v
        elif f == "--vcpus":
            vcpus = int(v)
        elif f == "--mem-mib":
            mem = int(v)
        else:
            raise SystemExit("ladder_levers: unknown flag %s" % f)
    if not re.fullmatch(r"[1-9][0-9]*", cohort):
        raise SystemExit("ladder_levers: COHORT %r" % cohort)
    rows = load(tsv)
    probs = check(rows)
    if probs:
        print("ladder_levers: the table fails its check:\n  " + "\n  ".join(probs), file=sys.stderr)
        return 1
    try:
        for w in notrun_resolution_warnings(rows, read_resolved(resd, ROOT, rows)):
            print("ladder_levers: warning: %s" % w, file=sys.stderr)
        res = resolve(rows, rung, int(cohort), resd)
    except (Unresolved, ValueError) as e:
        # A bad resolution (an alias winner outside alias_of, a source that is not a run dir, ...)
        # is a refusal like any other, not a traceback.
        print("ladder_levers: refused: %s" % e, file=sys.stderr)
        return 3
    if mem is not None:
        pr = fits(res, int(cohort), mem, vcpus)
        if pr:
            print("ladder_levers: refused: " + "; ".join(pr), file=sys.stderr)
            return 4
    p = res["params"]
    line = "; ".join(["RUNG=%s" % rung, "ARM=%s" % res["arm"], "COHORT=%s" % cohort, "WANT_N=%d" % res["want_n"]] +
                     ["%s=%s" % (k, p[k]) for k in KEYS])
    print("ARM=%s" % res["arm"])
    print("INSTANCE=%s" % res["instance"])
    print("AZ=%s" % res["az"])
    print("TTL_C1=%s" % res["ttl_c1"])
    print("WANT_N=%d" % res["want_n"])
    print("PARAMS='%s'" % line)
    return 0


def _copy(rows):
    return [collections.OrderedDict(r) for r in rows]


def _self_test_c10(rows, names, src, root):
    """The 2026-10-13 rulings and the c10 O-arm rows (hypothetical selections; SRC a results/ source)."""
    def h(**sel):
        out = {("S4", "10", "alias"): ("S4-t16", src), ("S8", "10", "alias"): ("S8-k2", src)}
        for k, v in sel.items():
            out[(k.replace("_", "-"), "10", "alias")] = (v, src)
        return out

    def refused(rung, res, want):
        try:
            resolve(rows, rung, 10, res=res, root=root)
        except Unresolved as e:
            assert want in str(e), (rung, want, e)
            return str(e)
        raise AssertionError("%s resolved at c10 (want %r)" % (rung, want))
    # Ruling 1: S4's pick carries to ours as a vCPU ratio. fill/R never oversubscribes, on any type.
    for t, (v, _) in load_types().items():
        for ratio in (1, 2, 3, 4, 6, 8, 12, 16, 24, 48, 96, 192):
            th = vc("vcpus/%d" % ratio, v)
            assert th * vc("fill/%d" % ratio, v) <= v, (t, ratio)
    assert (vc("vcpus/6", 8), vc("fill/6", 8), vc("vcpus/6", 16), vc("fill/6", 16), vc("fill/6", 96)) == (1, 8, 2, 8, 6)
    # S4 -> S4-t16 (16 of 96 vCPUs), S* = S9 (x8g.24xlarge): R = 6. O0 is S9's exact configuration.
    s9 = h(Sstar_time="S9", Sstar_cost="S9")
    v0, v9 = _values(rows, names["O0"], 10, s9)[0], _values(rows, names["S9"], 10, s9)[0]
    assert (v0["THREADS"], v0["PROCS"], v9["THREADS"], v9["PROCS"]) == ("vcpus/6", "fill/6", "16", "vcpus/16"), (v0, v9)
    assert all(same_value(k, v0[k], v0["instance"], v9[k], v9["instance"]) for k in VC_KEYS)
    r0 = resolve(rows, "O0", 10, res=s9, root=root)
    assert (r0["instance"], r0["params"]["THREADS"], r0["params"]["PROCS"], r0["want_n"]) == ("x8g.24xlarge", "vcpus/6", "6", 2), r0
    assert resolve(rows, "O0b", 10, res=s9, root=root)["params"]["INFLIGHT"] == "6"
    # On a 192-vCPU S* host the S arm carried T = 16 with P = vcpus/16 = 12: R = 12 there, so O0 stays S*'s.
    r8 = resolve(rows, "O0", 10, res=h(Sstar_time="Sstar-r8g", Sstar_cost="S9"), root=root)
    assert (r8["instance"], r8["params"]["THREADS"], r8["params"]["PROCS"]) == ("r8g.48xlarge", "vcpus/12", "12"), r8
    # The engine's in flight is clamped to the cohort: fill/12 is 12 on 192 vCPUs, but c10 has 10 samples.
    assert (vc("fill/12", 192), vc("fill/12/10", 192), vc("fill/6/10", 8), vc("fill/6/4", 96)) == (12, 10, 8, 4)
    r8b = resolve(rows, "O0b", 10, res=h(Sstar_time="Sstar-r8g", Sstar_cost="S9"), root=root)
    assert (r8b["params"]["INFLIGHT"], _values(rows, names["O0b"], 10, h(Sstar_time="Sstar-r8g", Sstar_cost="S9"))[0]["INFLIGHT"]) \
        == ("10", "fill/12/10"), r8b
    assert _values(rows, names["O0"], 10, h(Sstar_time="Sstar-r8g", Sstar_cost="S9"))[0]["PROCS"] == "fill/12"   # PROCS: S*'s own
    # The static one-lever check reads @ratio as its origin's own THREADS / PROCS text.
    assert changed(rows, names["O0"], names["Sstar-time"]) == ["CLASSIFIER"], changed(rows, names["O0"], names["Sstar-time"])
    t = _copy(rows)
    by_name(t)["O1"]["THREADS"] = "@ratio:Sstar-time:fill"
    assert any("O1: THREADS=@ratio:Sstar-time:fill" in p for p in check(t)), check(t)
    # 4. O2 at N = K: S8 -> S8-k2 (K = 2), so O1 is a 2-shard engine on S*'s host, and O2's candidates
    # are each family's smallest type holding table/2 (@fit:<family>), with the ratio at their vCPUs.
    rr, rx = resolve(rows, "O2-r8g", 10, res=s9, root=root), resolve(rows, "O2-x8g", 10, res=s9, root=root)
    assert (rr["instance"], rr["want_n"], rx["instance"], rx["want_n"]) == ("r8g.24xlarge", 2, "x8g.12xlarge", 2), (rr, rx)
    assert (rx["params"]["THREADS"], rx["params"]["INFLIGHT"]) == ("vcpus/6", "6"), rx   # 48 // 6 = 8 threads x 6
    assert resolve(rows, "O1", 10, res=s9, root=root)["params"]["SHARDS"] == "2"
    # ... and where S8 keeps K = 1 (hypothetically), O2-x8g is O1's own x8g.24xlarge: not a candidate there.
    k1 = dict(s9)
    k1[("S8", "10", "alias")] = ("S7b", src)
    refused("O2-x8g", k1, "is outside O2's candidates (its instance is that of O1 (O0b's runs)")
    assert resolve(rows, "O2-r8g", 10, res=k1, root=root)["instance"] == "r8g.48xlarge"
    # 5. O1 at K: K = 2 runs it; K = 1 makes it a conditional not-run (O0b's configuration), not a refusal.
    assert notrun_state(rows, names["O1"], 10, s9)[0] == "run"
    assert notrun_state(rows, names["O1"], 10, k1)[0] == "not-run"
    assert "conditional: it resolves to O0b's configuration" in refused("O1", k1, "no spec is generated for it")
    assert not_run_at(names["O1"], 10) == "" and not_run_at(names["O1"], 10, rows, k1).startswith("not-run at c10")
    assert config_row(rows, names["O1"], 10, k1)["rung"] == "O0b" and config_row(rows, names["O1"], 10, s9)["rung"] == "O1"
    assert notrun_state(rows, names["O1"], 100, {})[0] == "undecided"
    # 6. O3 at N = K: O3-n2 changes only the host against O2's N = 2 (O2's lever): not a candidate.
    for o2 in ("O1", "O2-r8g", "O2-x8g"):
        refused("O3-n2", {**s9, ("O2", "10", "alias"): (o2, src)}, "is outside O3's candidates (its REPLICAS+SHARDS is that of O2")
    assert resolve(rows, "O3-n4", 10, res={**s9, ("O2", "10", "alias"): ("O2-x8g", src)}, root=root)["instance"] == "x8g.8xlarge"
    # 3. Ruling 3: S* on r8gd and O2 -> O1 (r8gd.48xlarge): the floor uses r8g's small sizes.
    gd = h(Sstar_time="Sstar-r8gd", Sstar_cost="Sstar-r8gd", O2="O1", O2_cost="O1-cost")
    assert _values(rows, names["O2"], 10, gd)[0]["instance"] == "r8gd.48xlarge"
    r4 = resolve(rows, "O3-n4", 10, res=gd, root=root)
    assert r4["instance"].startswith("r8g.") and r4["params"]["THREADS"] == "vcpus/12", r4
    # 7. A conditional alias whose target is not a candidate there is 'own': O3-cost-n2 -> O3-n2 is one
    # configuration at c10, but O3-n2 is outside O3's candidates (O2's N), so it has no runs to read.
    x = {**s9, ("O2", "10", "alias"): ("O2-x8g", src), ("O2-cost", "10", "alias"): ("O2-cost-x8g", src)}
    a, b = _values(rows, names["O3-cost-n2"], 10, x)[0], _values(rows, names["O3-n2"], 10, x)[0]
    assert same_config(a, b)
    st = alias_state(rows, names["O3-cost-n2"], 10, x, root=root)
    assert st[0] == "own" and "is outside O3's candidates" in st[2], st
    assert alias_state(rows, names["O3-cost-n4"], 10, x, root=root)[0] == "alias"
    # ... and so for a target outside its alias's bracket (#26 fit predictions at c10 putting N* = 16:
    # the bracket is N in [8, 32], so O3-n4 is out and O3-cost-n4 reads its own runs; O3-n8 is in).
    with open(os.path.join(root, "results", "g3", "fit26", "predictions.tsv"), "w") as f:
        f.write("fit\tfamily\ttype\tcohort\tN\tT_pred_s\tusd_run_NpT\tstatus\n")
        for t_, n, tp in (("x8g.12xlarge", 2, 900), ("x8g.8xlarge", 4, 600), ("x8g.4xlarge", 8, 400), ("x8g.4xlarge", 16, 300),
                          ("x8g.2xlarge", 32, 350)):
            f.write("R\tx8g\t%s\t10\t%d\t%d\t%d\twithin data\n" % (t_, n, tp, n))
    st = alias_state(rows, names["O3-cost-n4"], 10, x, root=root)
    assert st[0] == "own" and "outside O3's bracket" in st[2], st
    assert alias_state(rows, names["O3-cost-n8"], 10, x, root=root)[0] == "alias"
    refused("O3-n4", x, "is outside O3's bracket")
    # ... and an in-flight range: with O3 -> O3-n8 (x8g.4xlarge: THREADS 2, O4a's INFLIGHT fill/6 = 8),
    # O4b-if8 is O4a's own, so O4b-cost-if8's conditional entry is 'own' (and it is out of its own range).
    x8 = {**x, ("O3", "10", "alias"): ("O3-n8", src), ("O3-cost", "10", "alias"): ("O3-cost-n8", src)}
    st = alias_state(rows, names["O4b-cost-if8"], 10, x8, root=root)
    assert st[0] == "own" and "outside O4b's range" in st[2], st
    assert alias_state(rows, names["O4b-cost-if4"], 10, x8, root=root)[0] == "alias"
    refused("O4b-cost-if8", x8, "is outside O4b-cost's range")
    # Ours never oversubscribes: a THREADS made absolute again on O4a is refused where it would.
    t = _copy(rows)
    by_name(t)["O4a"]["THREADS"] = "16"
    try:
        resolve(t, "O4a", 10, res=x8, root=root)
        raise AssertionError("an oversubscribed O rung resolved")
    except Unresolved as e:
        assert "oversubscribes x8g.4xlarge" in str(e) or "changes THREADS" in str(e), e


def _self_test():
    import tempfile
    rows = load(TSV)
    probs = check(rows)
    assert probs == [], probs
    names = by_name(rows)
    # The check resolves the effect: a second lever, a stale or missing coupling, a missing
    # counterpart, ETag off and a misplaced stock marker are each caught.
    t = _copy(rows)
    by_name(t)["S1"]["GUNZIP"] = "rapidgzip-P16"
    assert any(p.startswith("S1: changes DB_STAGE,GUNZIP") for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["S4"]["coupled"] = "DB_STAGE: a test reason"
    assert any("S4: coupled DB_STAGE does not change" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["S2c"]["IN_DEST"] = "nvme"   # S2a would then move the inputs and the host at once
    assert any(p.startswith("S2a: changes IN_DEST,instance") for p in check(t)), check(t)
    assert not any("S2a" in p for p in check(rows)) and names["S2a"]["coupled"] == ""
    # Two ladder-2 chains: each O*-endpoint's chain reaches its own S* endpoint.
    for top, root in (("O5", "Sstar-time"), ("O5-cost", "Sstar-cost")):
        r, seen = top, []
        while r != "-" and r not in seen:
            seen.append(r)
            r = names[r]["predecessor"]
        assert root in seen and "S0-T1" in seen, (top, seen)
    assert names["O3-cost"]["SHARDS"] == "@select:O3-cost" and names["O3"]["SHARDS"] == "@select:O3"
    t = _copy(rows)
    by_name(t)["S6"]["counterpart"] = "O9"
    assert any("S6: counterpart 'O9'" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["O5"]["ETAG_CHECK"] = "off"
    assert any("O5: ETAG_CHECK is off" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["S1"]["lever"] = "stock"
    assert any("S1: lever stock, want DB_STAGE" in p for p in check(t)), check(t)
    # Resolution: the c1 rungs resolve; S3 does not until a resolution with a source exists.
    for r in ("S0-T1", "S0-Tv", "S1", "S2b-i", "S2b-ii", "S2c", "S2a"):
        resolve(rows, r, 1, None)
    try:
        resolve(rows, "S3", 1, None)
        raise AssertionError("the not-run S3 resolved")
    except Unresolved as e:
        assert "not-run" in str(e), e
    assert names["S4"]["predecessor"] == "S2a" and names["S3"]["HOST_TUNES"] == "none"
    t = _copy(rows)
    by_name(t)["S3"]["HOST_TUNES"] = "precompact"
    assert any("S3: is not-run: no parameter change (the tune probe chose none) but changes HOST_TUNES" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["S4"]["predecessor"] = "S3"
    assert any("S4: predecessor S3 is not run" in p for p in check(t)), check(t)
    # Resolutions (NB3): a source must be a results/ path inside a run dir; S4 must give a vcpus
    # ratio; after resolving, a rung identical to its predecessor is refused.
    import shutil
    root = tempfile.mkdtemp(prefix="ak2-lv-")
    os.makedirs(os.path.join(root, "results", "g3", "run1", "tables"))
    open(os.path.join(root, "results", "g3", "run1", "manifest.json"), "w").write("{}")
    open(os.path.join(root, "results", "g3", "run1", "tables", "pxt.tsv"), "w").write("x\n")
    os.makedirs(os.path.join(root, "results", "loose"))
    open(os.path.join(root, "results", "loose", "pxt.tsv"), "w").write("x\n")
    src = "results/g3/run1/tables/pxt.tsv"

    def resfile(lines):
        p = os.path.join(root, "res.tsv")
        with open(p, "w") as f:
            f.write("origin\tcohort\tkey\tvalue\tsource\n" + "".join("\t".join(l) + "\n" for l in lines))
        return p
    try:
        # S4 is an alias over candidate rungs (S2a, S4-t48 ... S4-t1). c10: the winner S4-t8 (T = 8,
        # P = vcpus/8) would be refused there (P = 12 > 10), so take S4-t12 (P = 8); its THREADS and
        # PROCS reach S5 through the alias (any key resolves to the winner's value).
        good = resfile([("S4", "10", "alias", "S4-t12", src)])
        try:
            resolve(rows, "S4", 10, good, root)
            raise AssertionError("the alias S4 was generated")
        except Unresolved as e:
            assert "alias:" in str(e), e
        r5 = resolve(rows, "S5", 10, good, root)["params"]
        assert (r5["THREADS"], r5["PROCS"]) == ("12", "vcpus/12"), r5   # inherits S4's winner's values
        assert resolve(rows, "S4-t12", 10, good, root)["params"]["PROCS"] == "vcpus/12"
        assert vc("vcpus/8", vcpus_of("x8g.24xlarge")) == 12 and vc("vcpus/8", vcpus_of("r8g.48xlarge")) == 24
        for rung, c in (("S4-t8", 10), ("S4-t48", 1), ("S8-k2", 1)):
            try:
                resolve(rows, rung, c, good, root)
                raise AssertionError("%s resolved at c%d" % (rung, c))
            except Unresolved as e:
                assert "not-run at c%d" % c in str(e), e
        try:   # S8's winner is not resolved at c10, so S9 is not determined there.
            resolve(rows, "S9", 10, good, root)
            raise AssertionError("S9 resolved at c10 without S8")
        except Unresolved as e:
            assert "REPLICAS=@select:S8" in str(e), e
        r9 = resolve(rows, "S9", 10, resfile([("S4", "10", "alias", "S4-t12", src), ("S8", "10", "alias", "S8-k2", src)]), root)
        assert (r9["params"]["REPLICAS"], r9["want_n"], r9["params"]["PROCS"]) == ("2", 2, "vcpus/12"), r9
        # The alias's own predecessor is a candidate: S4 -> S2a at c10 makes S5 take S2a's values.
        r5 = resolve(rows, "S5", 10, resfile([("S4", "10", "alias", "S2a", src)]), root)["params"]
        assert (r5["THREADS"], r5["PROCS"]) == ("vcpus", "1"), r5
        try:   # a winner that is not a candidate at the cohort (S4-t8: 12 processes > 10)
            resolve(rows, "S5", 10, resfile([("S4", "10", "alias", "S4-t8", src)]), root)
            raise AssertionError("a winner not run at c10 was accepted")
        except ValueError as e:
            assert "is not a candidate there" in str(e), e
        # c1: S4 and S8 are not run (one candidate each, their predecessor's configuration); their
        # tokens resolve to that predecessor's values, so S5 ... S9 are determined at c1.
        for rung in ("S4", "S8"):
            try:
                resolve(rows, rung, 1, good, root)
                raise AssertionError("%s resolved at c1" % rung)
            except Unresolved as e:
                assert "alias:" in str(e) or "not-run at c1" in str(e), e
        r5 = resolve(rows, "S5", 1, good, root)["params"]
        assert (r5["THREADS"], r5["PROCS"]) == ("vcpus", "1"), r5
        assert resolve(rows, "S9", 1, good, root)["params"]["REPLICAS"] == "1"
        for lines, want in (([("S4", "10", "alias", "S4-t12", "results/g3/nope.tsv")], "does not exist"),
                            ([("S4", "10", "alias", "S4-t12", "results/loose/pxt.tsv")], "not inside a run"),
                            ([("S4", "10", "alias", "S4-t12", "/tmp/x")], "not a results/"),
                            ([("S4", "10", "THREADS", "8", src), ("S4", "10", "PROCS", "12", src)], "vcpus ratio")):
            try:
                resolve(rows, "S5", 10, resfile(lines), root)
                raise AssertionError("accepted: %s" % lines)
            except ValueError as e:
                assert want in str(e), (want, e)
        # The cites column (make ladder-select): each path=sha256 must exist under results/ and hash to it.
        import hashlib
        h = hashlib.sha256(b"x\n").hexdigest()
        p = os.path.join(root, "res7.tsv")
        for cite, want in (("%s=%s" % (src, h), None), ("%s=%s" % (src, "0" * 64), "changed since the selection"),
                           ("results/g3/run1/nope=%s" % h, "does not exist"), ("%s" % src, "not path=<sha256>"),
                           ("scripts/x=%s" % h, "not a results/")):
            with open(p, "w") as f:
                f.write("origin\tcohort\tkey\tvalue\tsource\tcites\tmargin\tnote\n"
                        "Sstar-time\t1\talias\tS9\t%s\t%s\tresolved\tn\n" % (src, cite))
            try:
                assert read_resolved(p, root)[("Sstar-time", "1", "alias")][0] == "S9" and want is None, (cite, want)
            except ValueError as e:
                assert want and want in str(e), (want, e)
        # The note's rule sha256: equal to the rule text's now, accepted; another, refused (the rule changed).
        ok = hashlib.sha256(names["Sstar-time"]["select"].encode()).hexdigest()
        for rs, want in ((ok, None), ("1" * 64, "the rule changed since the selection")):
            with open(p, "w") as f:
                f.write("origin\tcohort\tkey\tvalue\tsource\tcites\tmargin\tnote\n"
                        "Sstar-time\t1\talias\tS9\t%s\t\tresolved\trule sha256 %s: x\n" % (src, rs))
            try:
                assert read_resolved(p, root, rows)[("Sstar-time", "1", "alias")][0] == "S9" and want is None, (rs, want)
            except ValueError as e:
                assert want and want in str(e), (want, e)
        assert read_resolved(p, root)[("Sstar-time", "1", "alias")][0] == "S9"   # without the table: not checked
        # On values, not text: a candidate equal by value to its predecessor is refused. S4-t96 with
        # THREADS=96, PROCS=vcpus/96 is 96 threads x 1 process on x8g.24xlarge, S2a's THREADS=vcpus, PROCS=1.
        t = _copy(rows)
        x = collections.OrderedDict(by_name(t)["S4-t48"])
        x.update(rung="S4-t96", THREADS="96", PROCS="vcpus/96", not_run_cohorts="")
        t.append(x)
        try:
            resolve(t, "S4-t96", 10, None, root)
            raise AssertionError("a candidate identical to S2a by value was accepted")
        except Unresolved as e:
            assert "identical to S2a" in str(e), e
        # alias_cohorts: O0-cost reads O0's runs at c1 and is never generated there; a declaration whose
        # two rungs differ is refused; a cost rung equal to its time counterpart must be declared.
        al = resfile([("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "S9", src)])
        try:
            resolve(rows, "O0-cost", 1, al, root)
            raise AssertionError("O0-cost generated at c1")
        except Unresolved as e:
            assert "same configuration as O0 at c1" in str(e), e
        assert resolve(rows, "O0", 1, al, root)["instance"] == "x8g.24xlarge"
        assert alias_cohort_problems(rows, 1, read_resolved(al, root)) == []
        bad = resfile([("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "Sstar-r8gd", src)])
        pr = alias_cohort_problems(rows, 1, read_resolved(bad, root))
        assert any("O0-cost at c1 is declared an alias of O0" in x and "instance" in x for x in pr), pr
        try:
            resolve(rows, "O0", 1, bad, root)
            raise AssertionError("generated under a false alias_cohorts declaration")
        except Unresolved as e:
            assert "declared an alias of O0" in str(e), e
        t = _copy(rows)
        by_name(t)["O0b-cost"]["alias_cohorts"] = ""
        al = resfile([("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "S9", src)])
        try:
            resolve(t, "O0b-cost", 1, al, root)
            raise AssertionError("an undeclared coincidence was generated")
        except Unresolved as e:
            assert "declare alias_cohorts 'c1: O0b'" in str(e), e
        t = _copy(rows)
        by_name(t)["O0-cost"]["alias_cohorts"] = "c1: O9"
        assert any("alias_cohorts c1 names O9" in x for x in check(t)), check(t)
        # Conditional entries (`c1: O3-n2 (if same configuration)`: O3-cost-n<K>, O4a-cost, O5-cost):
        # whether the cost chain coincides with the time chain there depends on O2's and O2-cost's
        # selections. One family (O2 -> O1, O2-cost -> O1-cost, both O0b's x8g): an alias, never
        # generated, and its selection reads O3-n2's runs. Two families (O2 -> O2-r8g): its own
        # configuration, generated, and no declaration is false. O2-cost resolved but O2 not: undecided, refused.
        ONE = [("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "S9", src),
               ("O2", "1", "alias", "O1", src), ("O2-cost", "1", "alias", "O1-cost", src)]
        try:
            resolve(rows, "O3-cost-n2", 1, resfile(ONE), root)
            raise AssertionError("O3-cost-n2 generated where it is O3-n2's configuration")
        except Unresolved as e:
            assert "same configuration as O3-n2 at c1 (alias_cohorts, conditional: it holds)" in str(e), e
        assert resolve(rows, "O3-n2", 1, resfile(ONE), root)["instance"] == "x8g.12xlarge"
        assert config_row(rows, names["O3-cost-n2"], 1, read_resolved(resfile(ONE), root))["rung"] == "O3-n2"
        assert alias_state(rows, names["O4a-cost"], 1, read_resolved(resfile(ONE), root))[0] == "undecided"   # O3, O3-cost unselected
        TWO = [("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "S9", src),
               ("O2", "1", "alias", "O2-r8g", src), ("O2-cost", "1", "alias", "O1-cost", src)]
        st2 = alias_state(rows, names["O3-cost-n2"], 1, read_resolved(resfile(TWO), root))
        assert st2[0] == "own" and "instance" in st2[2], st2
        assert alias_cohort_problems(rows, 1, read_resolved(resfile(TWO), root)) == []
        assert resolve(rows, "O3-cost-n2", 1, resfile(TWO), root)["instance"] == "x8g.12xlarge"
        assert resolve(rows, "O3-n2", 1, resfile(TWO), root)["instance"] == "r8g.24xlarge"
        assert config_row(rows, names["O3-cost-n2"], 1, read_resolved(resfile(TWO), root))["rung"] == "O3-cost-n2"
        HALF = [("Sstar-time", "1", "alias", "S9", src), ("Sstar-cost", "1", "alias", "S9", src),
                ("O2-cost", "1", "alias", "O1-cost", src)]
        try:
            resolve(rows, "O3-cost-n2", 1, resfile(HALF), root)
            raise AssertionError("an undecided conditional entry was generated")
        except Unresolved as e:
            assert "is undecided" in str(e) and "O3-n2" in str(e), e
        assert config_row(rows, names["O3-cost-n2"], 1, read_resolved(resfile(HALF), root)) is None
        # The same pair declared unconditionally is false under TWO: refused, as any false declaration.
        t = _copy(rows)
        by_name(t)["O3-cost-n2"]["alias_cohorts"] = "c1: O3-n2"
        assert any("O3-cost-n2 at c1 is declared an alias of O3-n2" in x for x in alias_cohort_problems(t, 1, read_resolved(resfile(TWO), root)))
        # Without any declaration, the coincidence under ONE is refused, naming both forms.
        by_name(t)["O3-cost-n2"]["alias_cohorts"] = ""
        try:
            resolve(t, "O3-cost-n2", 1, resfile(ONE), root)
            raise AssertionError("an undeclared coincidence was generated")
        except Unresolved as e:
            assert "declare alias_cohorts 'c1: O3-n2'" in str(e) and "'c1: O3-n2 (if same configuration)'" in str(e), e
        # check(): a malformed entry, and a conditional entry on a rung that makes a selection.
        by_name(t)["O3-cost-n2"]["alias_cohorts"] = "c1: O3-n2 (if same)"
        assert any("alias_cohorts entry 'c1: O3-n2 (if same)' is not" in x for x in check(t)), check(t)
        by_name(t)["O3-cost-n2"]["alias_cohorts"] = ""
        by_name(t)["O0b-cost"]["alias_cohorts"] = "c1: O0b (if same configuration)"
        assert check(t) == [], check(t)
        by_name(t)["O2-cost-r8g"]["alias_cohorts"] = ""
        x = collections.OrderedDict(by_name(t)["O4b"])
        x.update(rung="O4b-x", not_run_cohorts="", alias_cohorts="c1: O4a (if same configuration)")
        t.append(x)
        assert any("O4b-x: a conditional alias_cohorts entry (c1) on a rung that makes a selection" in p for p in check(t)), check(t)
        # O2 at c1: O1 is not run (O0b's configuration), O2-x8g is O1's own type (not run), O2-r8g runs.
        o2 = resolve(rows, "O2-r8g", 1, al, root)
        assert (o2["instance"], o2["params"]["SHARDS"], o2["params"]["INFLIGHT"]) == ("r8g.48xlarge", "1", "1"), o2
        # O3's candidates take O2's winner's type; the bracket on the #26 fit (none in this root: widened).
        o3res = read_resolved(resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O2-r8g", src)]), root)
        b = bracket(rows, names["O3"], 1, o3res, root)
        assert b[0] == set(names["O3"]["alias_of"].split("|")) and "widened" in b[1], b
        os.makedirs(os.path.join(root, "results", "g3", "fit26"))
        with open(os.path.join(root, "results", "g3", "fit26", "predictions.tsv"), "w") as f:
            f.write("fit\tfamily\ttype\tcohort\tN\tT_pred_s\tusd_run_NpT\tstatus\n")
            # Each N on its own right-sized type (the prediction is looked up per candidate).
            for t, n, tp in (("r8g.48xlarge", 1, 500), ("r8g.24xlarge", 2, 400), ("r8g.12xlarge", 4, 300), ("r8g.8xlarge", 8, 310),
                             ("r8g.4xlarge", 16, 320), ("r8g.4xlarge", 32, 330), ("r8g.48xlarge", 4, 100)):
                f.write("R\tr8g\t%s\t1\t%d\t%d\t%d\twithin data\n" % (t, n, tp, n))
        b = bracket(rows, names["O3"], 1, o3res, root)
        assert b[0] == {"O3-n2", "O3-n4", "O3-n8"} and "is 4 on r8g.12xlarge" in b[1], b   # not r8g.48xlarge's N=4 row
        # The grid must be the candidates' N: a grid with 64 (no O3-n64 row) is refused.
        t = _copy(rows)
        by_name(t)["O3"]["select"] = by_name(t)["O3"]["select"].replace("{1, 2, 4, 8, 16, 32}", "{1, 2, 4, 8, 16, 32, 64}")
        try:
            bracket(t, by_name(t)["O3"], 1, o3res, root)
            raise AssertionError("a grid beyond the candidate rows was accepted")
        except Unresolved as e:
            assert "is not its candidate rows' N" in str(e), e
        # O3 right-sized per N (Scott, 2026-10-11): each O3-n<K> on the smallest type of O2's winning
        # family that holds table/K by fits(); the reviewer's types: x8g.4xlarge at 8, x8g.2xlarge at
        # 16 and 32, r8g.4xlarge at 16 (and r8g at 8 and 32 by the same rule).
        want = {("O1", 8): "x8g.4xlarge", ("O1", 16): "x8g.2xlarge", ("O1", 32): "x8g.2xlarge",
                ("O2-r8g", 8): "r8g.8xlarge", ("O2-r8g", 16): "r8g.4xlarge", ("O2-r8g", 32): "r8g.4xlarge"}
        for (w, k), typ in sorted(want.items()):
            rs = {("Sstar-time", "1", "alias"): ("S9", src), ("O2", "1", "alias"): (w, src)}
            for o3n in ("O3-n%d" % k, ):
                got = _values(rows, names[o3n], 1, rs)[0].get("instance")
                assert got == typ, (w, k, got, typ)
            gotc = _values(rows, names["O3-cost-n%d" % k], 1, {("Sstar-cost", "1", "alias"): ("S9", src),
                                                                ("O2-cost", "1", "alias"): ({"O1": "O1-cost", "O2-r8g": "O2-cost-r8g"}[w], src)})[0].get("instance")
            assert gotc == typ, ("cost", w, k, gotc, typ)
        rx = resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O1", src)])
        os.unlink(os.path.join(root, "results", "g3", "fit26", "predictions.tsv"))   # no fit: the bracket widens
        r16 = resolve(rows, "O3-n16", 1, rx, root)
        assert (r16["instance"], r16["want_n"], r16["params"]["THREADS"]) == ("x8g.2xlarge", 16, "vcpus"), r16
        # The host change is derived from SHARDS (the derived column's instance clause): without it,
        # the one-lever check counts it as the HOST group and refuses.
        t = _copy(rows)
        by_name(t)["O3-n16"]["derived"] = ""
        assert any(p.startswith("O3-n16: changes SHARDS,instance") for p in check(t)), check(t)
        try:
            resolve(t, "O3-n16", 1, rx, root)
            raise AssertionError("a host change without its derived declaration was accepted")
        except Unresolved as e:
            assert "not just the group REPLICAS+SHARDS" in str(e), e
        # O4a and O5 inherit O3's winner's right-sized host.
        w8 = {("Sstar-time", "1", "alias"): ("S9", src), ("O2", "1", "alias"): ("O1", src), ("O3", "1", "alias"): ("O3-n8", src)}
        assert _values(rows, names["O4a"], 1, w8)[0]["instance"] == "x8g.4xlarge"
        assert _values(rows, names["O5"], 1, w8)[0]["instance"] == "x8g.4xlarge"
        # derived_host is honoured only for @floor:<predecessor> (or @select:<self> on an alias whose
        # candidates all qualify). The reviewer's probes, each refused by the one-lever check:
        assert derived_host(rows, names["O3-n2"]) and derived_host(rows, names["O3"]) and derived_host(rows, names["O3-cost"])
        for rung, inst, der, want in (("S5", "r8g.48xlarge", "instance: a changed host", "S5: changes GUNZIP,instance"),
                                      ("O3-n2", "@floor:Sstar-time", None, "O3-n2: changes SHARDS,instance"),
                                      ("O3-n2", "c8g.48xlarge", None, "O3-n2: changes SHARDS,instance")):
            t = _copy(rows)
            x = by_name(t)[rung]
            x["instance"] = inst
            if der is not None:
                x["derived"] = der
            assert not derived_host(t, x), (rung, inst)
            assert any(p.startswith(want) for p in check(t)), (rung, inst, check(t))
            # ... and the O3 alias no longer qualifies once one of its candidates does not.
            if rung == "O3-n2":
                assert not derived_host(t, by_name(t)["O3"])
                assert any(p.startswith("O3: changes") for p in check(t)), check(t)
        with open(os.path.join(root, "results", "g3", "fit26", "predictions.tsv"), "w") as f:
            f.write("fit\tfamily\ttype\tcohort\tN\tT_pred_s\tusd_run_NpT\tstatus\n")
            for t_, n, tp in (("r8g.48xlarge", 1, 500), ("r8g.24xlarge", 2, 400), ("r8g.12xlarge", 4, 300), ("r8g.8xlarge", 8, 310),
                              ("r8g.4xlarge", 16, 320), ("r8g.4xlarge", 32, 330)):
                f.write("R\tr8g\t%s\t1\t%d\t%d\t%d\twithin data\n" % (t_, n, tp, n))
        try:
            resolve(rows, "O3-n16", 1, resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O2-r8g", src)]), root)
            raise AssertionError("a candidate outside the bracket was generated")
        except Unresolved as e:
            assert "outside O3's bracket" in str(e), e
        assert resolve(rows, "O3-n4", 1, resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O2-r8g", src)]), root)["want_n"] == 4
        # O4b's in-flight range (INFLIGHT 1 .. vCPUs / THREADS at O4a's host, O3's winning type). At c10
        # with S4 -> S4-t12 (12 of S9's 96 vCPUs: the O arm's ratio R = 8, ruling 1) and O3 -> O3-n2 on
        # x8g.12xlarge (48 vCPUs): THREADS = vcpus/8 = 6 there and O4a's INFLIGHT fill/8 = 48 // 6 = 8, the
        # bound; so O4b-if1, -if2 and -if4 are candidates, O4b-if8 is O4a itself and O4b-if16 and up are
        # above the bound (and not run at c10: k > cohort).
        h = {("S4", "10", "alias"): ("S4-t12", src), ("S8", "10", "alias"): ("S7b", src), ("Sstar-time", "10", "alias"): ("S9", src),
             ("O2", "10", "alias"): ("O1", src), ("O3", "10", "alias"): ("O3-n2", src)}
        v4a = _values(rows, names["O4a"], 10, h)[0]
        assert (v4a["instance"], v4a["THREADS"], v4a["INFLIGHT"]) == ("x8g.12xlarge", "vcpus/8", "fill/8/10"), v4a
        rg = inflight_range(rows, names["O4b"], 10, h)
        assert set(rg[0]) == {"O4b-if8", "O4b-if16", "O4b-if32", "O4b-if64", "O4b-if128"} and "1 .. 8" in rg[1], rg
        assert "O4a's own" in rg[0]["O4b-if8"] and "> vCPUs / THREADS = 48 // 6 = 8" in rg[0]["O4b-if16"], rg
        r2 = resolve(rows, "O4b-if2", 10, res=h)
        assert (r2["instance"], r2["params"]["INFLIGHT"], r2["params"]["THREADS"]) == ("x8g.12xlarge", "2", "vcpus/8"), r2
        assert resolve(rows, "O4a", 10, res=h)["params"]["INFLIGHT"] == "8"   # fill/8 at the pinned x8g.12xlarge
        for rung, want in (("O4b-if8", "is O4a's own"), ("O4b-if16", "not-run at c10")):
            try:
                resolve(rows, rung, 10, res=h)
                raise AssertionError("%s resolved at c10" % rung)
            except Unresolved as e:
                assert want in str(e), (rung, e)
        # THREADS = vcpus (S4 -> S2a): vCPUs / THREADS is 1 on every host, so every candidate is out and
        # O4b's only candidate is O4a (its selection then names O4a without a measurement).
        h2 = dict(h)
        h2[("S4", "10", "alias")] = ("S2a", src)
        rg = inflight_range(rows, names["O4b"], 10, h2)
        assert set(rg[0]) == set(names["O4b"]["alias_of"].split("|")[1:]) and "1 .. 1" in rg[1], rg
        # ... and O4a unresolved (O3 not selected): the range cannot be computed.
        h3 = dict(h)
        del h3[("O3", "10", "alias")]
        try:
            inflight_range(rows, names["O4b"], 10, h3)
            raise AssertionError("a range with O4a unresolved")
        except Unresolved as e:
            assert "its predecessor O4a is unresolved" in str(e), e
        assert inflight_range(rows, names["O3"], 10, h) is None   # no range clause
        # An alias's host is its winner's, and the winner must be one of alias_of.
        alias = resfile([("Sstar-time", "1", "alias", "Sstar-r8g", src)])
        assert _values(rows, names["Sstar-time"], 1, read_resolved(alias, root))[0]["instance"] == "r8g.48xlarge"
        try:
            _values(rows, names["Sstar-time"], 1, read_resolved(resfile([("Sstar-time", "1", "alias", "S4", src)]), root))
            raise AssertionError("an alias winner outside alias_of was accepted")
        except ValueError as e:
            assert "is not one of its alias_of" in str(e), e
        # A row for a cohort where the rung is not run is warned about (it is never used).
        w = notrun_resolution_warnings(rows, read_resolved(resfile([("S4", "1", "alias", "S4-t12", src)]), root))
        assert len(w) == 1 and all("S4 at c1" in x and "ignored" in x for x in w), w
        assert notrun_resolution_warnings(rows, read_resolved(resfile([("S4", "10", "alias", "S4-t12", src)]), root)) == []
        _self_test_c10(rows, names, src, root)
    finally:
        shutil.rmtree(root)
    # The command line refuses a bad alias winner cleanly (exit 3, a message), never a traceback.
    import contextlib
    import io
    real = "results/g3/20261009-060042-b6e1265/tables/phases.tsv"   # a committed run dir's file
    if os.path.exists(os.path.join(ROOT, real)):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
            f.write("origin\tcohort\tkey\tvalue\tsource\nSstar-time\t1\talias\tS4\t%s\n" % real)
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                rc = main(["params", "O0", "1", "--resolved", f.name])
        finally:
            os.unlink(f.name)
        assert rc == 3 and "refused" in err.getvalue() and "not one of its alias_of" in err.getvalue(), (rc, err.getvalue())
    t = _copy(rows)
    by_name(t)["S4"]["select"] = ""
    assert any("S4: makes a @select:S4 selection without a select rule" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["Sstar-time"]["alias_of"] = "S9|S99"
    assert any("Sstar-time: an alias needs alias_of" in p for p in check(t)), check(t)
    try:
        resolve(rows, "O0", 1, None)
        raise AssertionError("O0 resolved before S* is chosen")
    except Unresolved as e:
        assert "instance=@select:Sstar-time" in str(e), e
    assert instance_of(rows, names["O0"]) == "@select:Sstar-time"
    assert endpoint_rung(rows, 10, "S*-cost") == "Sstar-cost" and endpoint_rung(rows, 1000, "O*-time") == "O5"
    t = _copy(rows)
    by_name(t)["S9"]["endpoint"] = "c1:S*-time"
    assert any("c1:S*-time is declared on S9 and Sstar-time" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["O5"]["endpoint"] = "c1:O*-time"
    assert any("c10:O*-time is declared on no rung" in p for p in check(t)), check(t)
    assert token("@select:S4:PROCS", "INFLIGHT") == ("S4", "PROCS")
    assert token("@select:S8", "REPLICAS") == ("S8", "REPLICAS")
    assert assign([5, 9, 1, 9], 2, "lpt") == [0, 0, 1, 1] and assign([5, 9, 1], 2, "mod") == [0, 1, 0]
    # Memory: the c1 rungs fit their hosts; RODA on tmpfs does not fit 512 GiB.
    for r in ("S0-T1", "S1", "S2b-i", "S2b-ii", "S2c", "S2a"):
        assert fits(resolve(rows, r, 1, None), 1, 1572864) == [], r
    assert fits(resolve(rows, "S2a", 1, None), 1, 524288)
    # manifest params from a spec's PARAMS block; other specs give none.
    sp = spec_params({"command": ["bash", "-c", "x\n" + PARAMS_MARK + " S S1 1):\n"
                                  "RUNG=S1; ARM=S; COHORT=1; WANT_N=1; THREADS=vcpus\ny\n"]})
    assert sp == {"rung": "S1", "arm": "S", "cohort": 1, "want_n": 1, "threads": "vcpus", "run_kind": "ladder",
                  "state": "cold", "source": "spec command[2] PARAMS block"}, sp
    assert spec_params({"command": ["bash", "-c", "# Parameters (scripts/g3/mkspec.sh):\nEXP=e1; COHORT=1\n"]}) is None
    assert spec_params({"command": ["bash", "-c"]}) is None
    # The launch's rep (AK2_LADDER_REP): added with its source; refused on a non-ladder spec, a bad
    # value, or a PARAMS block naming another REP.
    sp1 = {"command": ["bash", "-c", "x\n" + PARAMS_MARK + " S S1 1):\nRUNG=S1; ARM=S; COHORT=1\n"]}
    assert spec_params_rep(sp1, "2")["rep"] == 2 and spec_params_rep(sp1, 1)["rep_source"] == REP_SOURCE
    for bad in ("0", "x", "-1", ""):
        try:
            spec_params_rep(sp1, bad)
            raise AssertionError("rep %r accepted" % bad)
        except ValueError:
            pass
    sp3 = {"command": ["bash", "-c", "x\n" + PARAMS_MARK + " S S1 1):\nRUNG=S1; REP=3\n"]}
    assert spec_params_rep(sp3, 3)["rep"] == 3
    for spec, r in ((sp3, 2), ({"command": ["bash", "-c", "echo"]}, 1)):
        try:
            spec_params_rep(spec, r)
            raise AssertionError("refusal missed")
        except ValueError:
            pass
    # The AZ list: a listed row whose evidence manifest holds is accepted; unlisted, or evidence that
    # records another AZ, is refused.
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "results", "g3", "r1"))
        with open(os.path.join(d, "results", "g3", "r1", "manifest.json"), "w") as f:
            json.dump({"instance": {"type": "x8g.24xlarge", "az": "us-west-2c"}}, f)
        azp = os.path.join(d, "azs.tsv")
        with open(azp, "w") as f:
            f.write("# c\ntype\taz\tevidence\nx8g.24xlarge\tus-west-2c\tresults/g3/r1/manifest.json\n"
                    "x8g.24xlarge\tus-west-2a\tresults/g3/r1/manifest.json\n")
        assert az_alt("x8g.24xlarge", "us-west-2c", azp, d, tracked=False)["evidence"] == "results/g3/r1/manifest.json"
        try:   # the same evidence, not committed (the temp dir is no repo): refused
            az_alt("x8g.24xlarge", "us-west-2c", azp, d)
            raise AssertionError("untracked evidence accepted")
        except ValueError as e:
            assert "not committed" in str(e), e
        for t, z in (("x8g.24xlarge", "us-west-2a"), ("x8g.24xlarge", "us-west-2d"), ("r8g.48xlarge", "us-west-2c")):
            try:
                az_alt(t, z, azp, d, tracked=False)
                raise AssertionError("az %s %s accepted" % (t, z))
            except ValueError:
                pass
    # The committed list's evidence holds.
    for r in az_rows():
        az_alt(r["type"], r["az"])
    print("ladder_levers: self-test ok (%d rows)" % len(rows))
    return 0


def main(a):
    if a and a[0] == "--self-test":
        return _self_test()
    if a and a[0] == "check":
        # check [TSV] [--resolved RES]: any table given is checked in full, its alias_cohorts
        # declarations against RES (default: the committed ladder.resolved.tsv).
        args, resd = a[1:], RESOLVED
        if "--resolved" in args:
            i = args.index("--resolved")
            if i + 1 >= len(args):
                print("ladder_levers: --resolved needs a file", file=sys.stderr)
                return 2
            resd = args[i + 1]
            args = args[:i] + args[i + 2:]
        rows = load(args[0] if args else TSV)
        probs = check(rows)
        for r in rows:
            if r["predecessor"] == "-":
                continue
            co = coupled_keys(r)
            print("%-11s %-26s from %-11s %s" % (r["rung"], r["group"], r["predecessor"],
                                                 "coupled: " + "+".join(sorted(co)) if co else ""))
        # Every alias_cohorts declaration whose two rungs resolve must be the same configuration.
        if not probs:
            try:
                res = read_resolved(resd, ROOT, rows)
                for c in sorted({int(d.split(":")[0].strip().lstrip("c")) for r in rows
                                 for d in r["alias_cohorts"].split(";") if d.strip()}):
                    probs += alias_cohort_problems(rows, c, res)
            except ValueError as e:
                probs.append("%s: %s" % (os.path.relpath(resd, ROOT) if os.path.isabs(resd) else resd, e))
        if probs:
            print("ladder_levers: %d problem(s):\n  %s" % (len(probs), "\n  ".join(probs)), file=sys.stderr)
            return 1
        # Each conditional entry's state under RES (an alias, its own configuration, or undecided).
        cst = []
        for r in rows:
            for d in [d.strip() for d in r["alias_cohorts"].split(";") if d.strip()]:
                c = d.split(":")[0].strip().lstrip("c")
                if alias_decl(r, c)[1]:
                    st, t, why = alias_state(rows, r, c, res)
                    cst.append("%s c%s -> %s: %s%s" % (r["rung"], c, t, st, " (%s)" % why if why else ""))
            for d in [d.strip() for d in r["not_run_cohorts"].split(";") if d.strip()]:
                c = d.split(":")[0].strip().lstrip("c")
                if notrun_decl(r, c)[1]:
                    st, why = notrun_state(rows, r, c, res)
                    cst.append("%s c%s not_run_cohorts (conditional): %s%s" % (r["rung"], c, st, " (%s)" % why if why else ""))
        print("ladder_levers: %d rungs; every rung changes exactly one key-group; every unconditional alias_cohorts pair "
              "that resolves is one configuration; %d conditional entr%s%s" % (len(rows), len(cst), "y" if len(cst) == 1 else "ies",
                                                                             "".join("\n  " + x for x in cst)))
        return 0
    if a and a[0] == "spec-params" and (len(a) == 2 or (len(a) == 4 and a[2] == "--rep")):
        with open(a[1]) as f:
            spec = json.load(f)
        if len(a) == 4:
            try:
                print(json.dumps(spec_params_rep(spec, a[3]), separators=(",", ":")))
            except ValueError as e:
                print("ladder_levers: refused: %s" % e, file=sys.stderr)
                return 3
            return 0
        print(json.dumps(spec_params(spec), separators=(",", ":")))
        return 0
    if a and a[0] == "az-alt" and len(a) == 3:
        try:
            print(json.dumps(az_alt(a[1], a[2]), separators=(",", ":")))
        except ValueError as e:
            print("ladder_levers: refused: %s" % e, file=sys.stderr)
            return 3
        return 0
    if a and a[0] == "params" and len(a) >= 3:
        return _params_main(a[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
