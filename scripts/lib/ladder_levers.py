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


def changed(rows, row, pred):
    keys = [k for k in KEYS if row[k] != pred[k]]
    if row["instance"] != "=pred" and instance_of(rows, row) != instance_of(rows, pred):
        keys.append("instance")
    return keys


def candidates_of(rows):
    """candidate rung -> the alias rung whose alias_of names it (the S* endpoints, and every selection's
    candidate rungs)."""
    return {c: r["rung"] for r in rows if r["status"].startswith("alias:") for c in r["alias_of"].split("|") if c}


def alias_at(row, cohort):
    """The rung whose runs ROW reads at COHORT (`alias_cohorts`: c<C>: <rung>), or ''."""
    for d in [d.strip() for d in row.get("alias_cohorts", "").split(";") if d.strip()]:
        c, _, t = d.partition(":")
        if c.strip() == "c%s" % cohort:
            return t.strip()
    return ""


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
        derives = any(r[k].startswith("@select:") for k in KEYS) or r["instance"].startswith("@select:")
        if r["not_run_cohorts"] and not (r["select"] or n in candidate_of or derives):
            probs.append("%s: not run at some cohorts, but it makes, is or derives from no selection there" % n)
        for d in [d.strip() for d in r.get("alias_cohorts", "").split(";") if d.strip()]:
            m = re.fullmatch(r"c([1-9][0-9]*): (\S+)", d)
            if not m:
                probs.append("%s: alias_cohorts entry %r is not c<cohort>: <rung>" % (n, d))
                continue
            t = names.get(m.group(2))
            if t is None or t["rung"] == n or t["arm"] != r["arm"] or t["status"].startswith("not-run"):
                probs.append("%s: alias_cohorts c%s names %s, not another rung of arm %s that is run" % (n, m.group(1), m.group(2), r["arm"]))
            if st != "run":
                probs.append("%s: alias_cohorts on a rung whose status is %r (want run)" % (n, st))
            if m.group(1) in [x.split(":")[0].strip().lstrip("c") for x in r["not_run_cohorts"].split(";") if x.strip()]:
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
        free = [k for k in ch if k not in co]
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


def not_run_at(row, cohort):
    """'' if the row runs at COHORT, else why not (status not-run, or a not_run_cohorts entry)."""
    if row["status"].startswith("not-run"):
        return row["status"]
    for d in [d.strip() for d in row.get("not_run_cohorts", "").split(";") if d.strip()]:
        if d.split(":", 1)[0] == "c%s" % cohort:
            return "not-run at c%s:%s" % (cohort, d.split(":", 1)[1])
    return ""


def run_pred_at(rows, row, cohort):
    """The nearest predecessor that runs at COHORT (not-run ones are skipped), or None."""
    p, seen = pred_of(rows, row), set()
    while p is not None and not_run_at(p, cohort) and p["rung"] not in seen:
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
    its run predecessor if it is not run there, its alias_cohorts target, or its alias winner (RES).
    None if an alias on the way is unresolved."""
    names, seen = by_name(rows), seen or []
    if row is None or row["rung"] in seen:
        return None
    seen = seen + [row["rung"]]
    if not_run_at(row, cohort):
        return config_row(rows, run_pred_at(rows, row, cohort), cohort, res, seen)
    t = alias_at(row, cohort)
    if t:
        return config_row(rows, names.get(t), cohort, res, seen)
    if row["status"].startswith("alias:"):
        a = alias_winner(rows, row, cohort, res)
        return config_row(rows, names.get(a[0]), cohort, res, seen) if a else None
    return row


def _values(rows, r, cohort, res, depth=0):
    """Every PARAM and the instance of row r at cohort under resolutions res: (values, unresolved).
    A token @select:<origin>[:KEY] resolves, in this order: an origin not run at the cohort to its
    run predecessor's value; an origin aliased there (alias_cohorts) to its target's; an alias origin
    (status alias) to its winner's value of that key, the winner named in res; any other origin to
    res's (origin, cohort, KEY) row."""
    if depth > 40:
        raise ValueError("%s: the @select tokens form a loop" % r["rung"])
    names = by_name(rows)
    bad, out = [], {}
    for k in KEYS + ["instance"]:
        v = instance_of(rows, r) if k == "instance" else r[k]
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
                elif o is not None and alias_at(o, cohort):
                    src, how = names.get(alias_at(o, cohort)), "alias at c%s of %s" % (cohort, alias_at(o, cohort))
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
        if not SAFE.match(v) and not re.fullmatch(r"vcpus/[1-9][0-9]*", v):
            bad.append("%s=%s (not a shell-safe word)" % (k, v))
        out[k] = v
    return out, bad


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
    """Each alias_cohorts declaration at COHORT must name a rung whose resolved configuration equals
    the declaring rung's. One that cannot be resolved yet is not a problem here (the generator
    refuses either rung until it is)."""
    names, out = by_name(rows), []
    for r in rows:
        t = alias_at(r, cohort)
        if not t or t not in names:
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
    of fit <F>'s time|cost-optimal N over {1, 2, ...} for ... type ..., widened to every candidate
    where that prediction is extrapolated or the type has none"): (the candidate names inside the
    bracket at COHORT, how, [cited files]). None if the rule has no bracket. Raises Unresolved while
    the candidates' type is not resolved."""
    m = re.search(r"bracket: .*?fit (\S+)'s (time|cost)-optimal N over \{([0-9, ]+)\}", alias_row["select"])
    if not m:
        return None
    fit, obj, grid = m.group(1), m.group(2), [int(x) for x in m.group(3).split(",")]
    names = by_name(rows)
    cands = [c for c in alias_row["alias_of"].split("|") if c]
    vals = {}
    for c in cands:
        v, bad = _values(rows, names[c], cohort, res)
        if bad:
            raise Unresolved("%s at c%s: candidate %s is unresolved (%s), so its bracket cannot be computed"
                             % (alias_row["rung"], cohort, c, ", ".join(bad)))
        vals[c] = v
    types = {v["instance"] for v in vals.values()}
    if len(types) != 1:
        raise Unresolved("%s at c%s: its candidates are on more than one type (%s)" % (alias_row["rung"], cohort, ", ".join(sorted(types))))
    itype = types.pop()
    path = os.path.join("results", "g3", "fit26", "predictions.tsv")
    full = os.path.join(root, path)
    best = None
    if os.path.isfile(full):
        import csv
        with open(full) as f:
            for p in csv.DictReader(f, delimiter="\t"):
                if p["fit"] == fit and p["type"] == itype and p["cohort"] == str(cohort) and int(p["N"]) in grid:
                    y = float(p["T_pred_s"] if obj == "time" else p["usd_run_NpT"])
                    if best is None or (y, int(p["N"])) < (best[0], best[1]):
                        best = (y, int(p["N"]), p["status"])
    cited = [path] if os.path.isfile(full) else []
    if best is None:
        return set(cands), "widened: fit %s has no %s prediction for %s at c%s" % (fit, obj, itype, cohort), cited
    if best[2] != "within data":
        return set(cands), "widened: fit %s's %s-optimal N for %s at c%s is %d, %s" % (fit, obj, itype, cohort, best[1], best[2]), cited
    inside = {c for c in cands if best[1] / 2 <= int(vals[c]["SHARDS"]) <= 2 * best[1]}
    return inside, "fit %s's %s-optimal N for %s at c%s is %d (within data): N in [%g, %d]" % (
        fit, obj, itype, cohort, best[1], best[1] / 2, 2 * best[1]), cited


def notrun_resolution_warnings(rows, res):
    """Warnings for resolution rows given for a rung at a cohort where it is not run: at such a
    cohort its tokens resolve to its predecessor's values, so the row is never used."""
    names, out = by_name(rows), []
    for (o, c, k), (v, src) in sorted(res.items()):
        r = names.get(o)
        if r is not None and not_run_at(r, c):
            out.append("ladder.resolved.tsv: %s at c%s (%s=%s, from %s) is ignored: %s" % (o, c, k, v, src, not_run_at(r, c)))
    return out


def resolve(rows, rung, cohort, resolved=None, root=ROOT):
    """{'params': {K: v}, 'instance', 'az', 'ttl_c1', 'arm', 'want_n'}; raises Unresolved. After
    resolving, the one-lever rule is checked again on the resolved values against the resolved
    predecessor (an alias predecessor is its winner, a not-run one is skipped): a resolution that
    makes the rung identical to its predecessor, or changes another key-group, is refused."""
    names = by_name(rows)
    if rung not in names:
        raise KeyError("no rung %s in the table" % rung)
    r = names[rung]
    if r["status"] != "run":
        raise Unresolved("%s is %s: no spec is generated for it" % (rung, r["status"]))
    why = not_run_at(r, cohort)
    if why:
        raise Unresolved("%s is %s: no spec is generated for it" % (rung, why))
    if alias_at(r, cohort):
        raise Unresolved("%s is alias: same configuration as %s at c%s (alias_cohorts): no spec is generated for it; "
                         "%s's runs are read" % (rung, alias_at(r, cohort), cohort, alias_at(r, cohort)))
    res = read_resolved(resolved, root, rows) if resolved is not None else {}
    probs = alias_cohort_problems(rows, cohort, res)
    if probs:
        raise Unresolved("; ".join(probs))
    out, bad = _values(rows, r, cohort, res)
    if bad:
        raise Unresolved("%s at cohort %s has unresolved values: %s" % (rung, cohort, ", ".join(bad)))
    # The cost chain reads the time chain where the two coincide (alias_cohorts), so a cost rung
    # equal to its time counterpart must be declared there, not run twice.
    tc = time_counterpart(rows, rung)
    if tc is not None and names[tc]["status"] == "run" and not not_run_at(names[tc], cohort) and not alias_at(names[tc], cohort):
        tv, tbad = _values(rows, names[tc], cohort, res)
        if not tbad and same_config(dict(out), tv):
            raise Unresolved("%s at cohort %s has the configuration of its time counterpart %s: declare alias_cohorts "
                             "'c%s: %s' (it reads %s's runs) instead of running it" % (rung, cohort, tc, cohort, tc, tc))
    # A candidate outside its alias's bracket at this cohort (O3's N around the #26 fit) is not run.
    al = candidates_of(rows).get(rung)
    if al is not None:
        b = bracket(rows, names[al], cohort, res, root)
        if b is not None and rung not in b[0]:
            raise Unresolved("%s at cohort %s is outside %s's bracket (%s): not a candidate there" % (rung, cohort, al, b[1]))
    p = run_pred_at(rows, r, cohort)
    if p is not None and (p["status"].startswith("alias:") or alias_at(p, cohort)):
        p = config_row(rows, p, cohort, res) or p
    if p is not None:
        pv, pbad = _values(rows, p, cohort, res)
        if pbad:
            raise Unresolved("%s at cohort %s: its predecessor %s is unresolved (%s), so the one-lever check cannot run"
                             % (rung, cohort, p["rung"], ", ".join(pbad)))
        ch = [k for k in KEYS if not same_value(k, out[k], out["instance"], pv[k], pv["instance"])]
        if out["instance"] != pv["instance"]:
            ch.append("instance")
        free = [k for k in ch if k not in coupled_keys(r)]
        groups = sorted({GROUP[k] for k in free})
        if not ch:
            raise Unresolved("%s at cohort %s: the resolution makes it identical to %s (mark it not-run instead)"
                             % (rung, cohort, p["rung"]))
        if groups != [r["group"]]:
            raise Unresolved("%s at cohort %s: resolved, it changes %s against %s, not just the group %s"
                             % (rung, cohort, ",".join(ch), p["rung"], r["group"]))
    inst = out.pop("instance")
    want = int(out["REPLICAS"]) * int(out["SHARDS"])
    return {"params": out, "instance": inst, "az": r["az"], "ttl_c1": r["ttl_min_c1"], "arm": r["arm"], "want_n": want}


def cohort_runs(cohort, path=RUNS):
    rows = []
    with open(path) as f:
        head = f.readline().rstrip("\n").split("\t")
        for l in f:
            d = dict(zip(head, l.rstrip("\n").split("\t")))
            if int(d["rank"]) <= cohort:
                rows.append((d["run"], int(d["read_count"]), int(d["bytes_1"]) + int(d["bytes_2"])))
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
            for n, tp in ((1, 500), (2, 400), (4, 300), (8, 310), (16, 320), (32, 330), (64, 340)):
                f.write("R\tr8g\tr8g.48xlarge\t1\t%d\t%d\t%d\twithin data\n" % (n, tp, n))
        b = bracket(rows, names["O3"], 1, o3res, root)
        assert b[0] == {"O3-n2", "O3-n4", "O3-n8"}, b
        try:
            resolve(rows, "O3-n16", 1, resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O2-r8g", src)]), root)
            raise AssertionError("a candidate outside the bracket was generated")
        except Unresolved as e:
            assert "outside O3's bracket" in str(e), e
        assert resolve(rows, "O3-n4", 1, resfile([("Sstar-time", "1", "alias", "S9", src), ("O2", "1", "alias", "O2-r8g", src)]), root)["want_n"] == 4
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
        rows = load(a[1] if len(a) > 1 else TSV)
        probs = check(rows)
        for r in rows:
            if r["predecessor"] == "-":
                continue
            co = coupled_keys(r)
            print("%-11s %-26s from %-11s %s" % (r["rung"], r["group"], r["predecessor"],
                                                 "coupled: " + "+".join(sorted(co)) if co else ""))
        # Every alias_cohorts declaration whose two rungs resolve (with the committed ladder.resolved.tsv,
        # for the committed table only) must be the same configuration.
        if len(a) == 1 and not probs:
            try:
                res = read_resolved(RESOLVED, ROOT, rows)
                for c in sorted({int(d.split(":")[0].strip().lstrip("c")) for r in rows
                                 for d in r["alias_cohorts"].split(";") if d.strip()}):
                    probs += alias_cohort_problems(rows, c, res)
            except ValueError as e:
                probs.append("scripts/g3/ladder.resolved.tsv: %s" % e)
        if probs:
            print("ladder_levers: %d problem(s):\n  %s" % (len(probs), "\n  ".join(probs)), file=sys.stderr)
            return 1
        print("ladder_levers: %d rungs; every rung changes exactly one key-group; every alias_cohorts pair that resolves "
              "is one configuration" % len(rows))
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
