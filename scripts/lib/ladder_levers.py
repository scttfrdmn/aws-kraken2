#!/usr/bin/env python3
"""The #25 ladder lever table (scripts/g3/ladder.levers.tsv; #51, docs/ladder.md): load, check, resolve.

  ladder_levers.py check [TSV]                      every rung changes exactly one key-group (Law 5)
  ladder_levers.py params RUNG COHORT [--mem-mib M] [--tsv TSV] [--resolved RES]
                                                    the rung's resolved PARAMs as shell-safe lines, for
                                                    scripts/g3/mkspec-ladder.sh; exit 3 if any value is
                                                    still a placeholder, 4 if the type cannot hold it
  ladder_levers.py spec-params SPEC.json            the spec's `params` object for manifest.json and
                                                    cohort.json (null if not a ladder spec)
  ladder_levers.py --self-test

Importable (the fuller ladder_check.py of #53 builds on it): load(), check(), resolve(), changed(),
coupled_keys(), spec_params(), GROUP, KEYS.

The one-lever rule (check): a rung's PARAMs and instance type are compared with its predecessor's.
The changed keys, less the keys its `coupled` column names (each with its reason), must all fall in
one key-group, the rung's `group`. Every coupled key must really change (no stale coupling) and lie
outside that group. The instance type is the key-group HOST. A predecessor of @Sstar (the S*
endpoint ladder 2 starts from, chosen from the record) is checked as S9: every S* candidate (S9,
Sstar-r8g, Sstar-r8gd) has S9's PARAMs and differs only in host. `lever` is what #52's tables
report: the group, or `stock` on S0-T1 and S0-Tv. Every rung names a counterpart rung on the other
ladder that exists, or says "none: <reason>". ETAG_CHECK is on in every row.
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

KEYS = ("CLASSIFIER THREADS PROCS DB_STAGE DB_PLACE DB_LOAD HOST_TUNES GUNZIP IN_FETCH IN_CLIENT IN_DEST "
        "OUT_UPLOAD REPLICAS SHARDS PLACEMENT INFLIGHT SETUP ETAG_CHECK").split()
GROUPS = ["CLASSIFIER", "THREADS+PROCS", "DB_STAGE", "DB_PLACE+DB_LOAD", "HOST_TUNES", "GUNZIP",
          "IN_FETCH+IN_CLIENT+IN_DEST", "OUT_UPLOAD", "REPLICAS+SHARDS", "PLACEMENT", "INFLIGHT", "SETUP",
          "ETAG_CHECK", "HOST"]
GROUP = {k: g for g in GROUPS for k in g.split("+")}
GROUP["instance"] = "HOST"
COLS = ["rung", "arm", "predecessor", "lever", "group", "coupled", "counterpart", "phase", "endpoint",
        "pred_wall_s", "pred_usd", "pred_phase_s", "instance", "az", "ttl_min_c1"] + KEYS + ["note"]
LABELS = {"S0-T1": "stock", "S0-Tv": "threads"}   # lever labels #52's tables read; others: the group
ENDPOINTS = {"S": ("S*-time", "S*-cost"), "O": ("O*-time", "O*-cost")}
COHORTS = (1, 10, 100, 1000)
SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
# Allowed literal values (ladder.body.sh checks the same); placeholders start with @.
ALLOWED = {
    "CLASSIFIER": r"upstream|ours-plain|ours-engine", "THREADS": r"vcpus|[1-9][0-9]*", "PROCS": r"[1-9][0-9]*",
    "DB_STAGE": r"awscp-default|s5cmd|ranged-get", "DB_PLACE": r"nvme|tmpfs|memory", "DB_LOAD": r"load|mmap|resident",
    "HOST_TUNES": r"none|precompact|proactive|defer|defermadv|always", "GUNZIP": r"gzip|rapidgzip-P([1-9][0-9]*|auto)",
    "IN_FETCH": r"serial|lanes[1-9][0-9]*", "IN_CLIENT": r"default|classic|crt", "IN_DEST": r"nvme|tmpfs",
    "OUT_UPLOAD": r"awscp-default|s5cmd-serial|s5cmd-overlap|sdk-stream", "REPLICAS": r"[1-9][0-9]*",
    "SHARDS": r"[1-9][0-9]*", "PLACEMENT": r"mod|lpt", "INFLIGHT": r"-|[1-9][0-9]*", "SETUP": r"serial|overlap",
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


def check(rows):
    probs = []
    names = by_name(rows)
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


def read_resolved(path):
    """(origin, cohort, key) -> (value, source); an absent file: no resolutions."""
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path) as f:
        for l in f:
            if l.startswith("#") or not l.strip() or l.startswith("origin\t"):
                continue
            o, c, k, v, src = (l.rstrip("\n").split("\t") + [""] * 5)[:5]
            if not src.strip():
                raise ValueError("%s: resolution %s/%s/%s has no source (a results/ path)" % (path, o, c, k))
            out[(o, c, k)] = (v, src)
    return out


def token(v, key):
    """A placeholder's (origin, key) lookup: @probe-tune is S3's HOST_TUNES; @select:R[:KEY]."""
    if v == "@probe-tune":
        return ("S3", "HOST_TUNES")
    m = re.fullmatch(r"@select:([A-Za-z0-9-]+)(?::([A-Z_]+|instance))?", v)
    if m:
        return (m.group(1), m.group(2) or key)
    return None


def resolve(rows, rung, cohort, resolved=None):
    """{'params': {K: v}, 'instance', 'az', 'ttl_c1', 'arm', 'want_n'}; raises Unresolved."""
    names = by_name(rows)
    if rung not in names:
        raise KeyError("no rung %s in the table" % rung)
    r = names[rung]
    res = read_resolved(resolved) if resolved is not None else {}
    bad, out = [], {}
    for k in KEYS + ["instance"]:
        v = instance_of(rows, r) if k == "instance" else r[k]
        if v.startswith("@"):
            t = token(v, k)
            hit = res.get((t[0], str(cohort), t[1])) if t else None
            if hit is None:
                bad.append("%s=%s" % (k, v))
                continue
            v = hit[0]
        if not SAFE.match(v):
            bad.append("%s=%s (not a shell-safe word)" % (k, v))
        out[k] = v
    if bad:
        raise Unresolved("%s at cohort %s has unresolved values: %s" % (rung, cohort, ", ".join(bad)))
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


def fits(res, cohort, mem_mib):
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
        inflight = int(p["INFLIGHT"]) if p["INFLIGHT"] != "-" else 1
        ram += int(1.15 * HASH_BYTES / sh) + 8 * 10 ** 9 + int(7.5 * 10 ** 9) * inflight
        why.append("engine shard 1/%d x 1.15 + 8 GB + 7.5 GB x %d in flight (scripts/g3/mkspec.sh's rule)" % (sh, inflight))
    elif p["DB_PLACE"] == "tmpfs":
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


def _params_main(a):
    tsv, resd, mem = TSV, RESOLVED, None
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
        res = resolve(rows, rung, int(cohort), resd)
    except Unresolved as e:
        print("ladder_levers: refused: %s" % e, file=sys.stderr)
        return 3
    if mem is not None:
        pr = fits(res, int(cohort), mem)
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
    by_name(t)["S2a"]["IN_DEST"] = "nvme"
    by_name(t)["S3"]["IN_DEST"] = "nvme"
    assert any("S2a: coupled IN_DEST does not change" in p for p in check(t)), check(t)
    t = _copy(rows)
    by_name(t)["S2a"]["coupled"] = ""
    assert any(p.startswith("S2a: changes IN_DEST,instance") for p in check(t)), check(t)
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
    for r in ("S0-T1", "S0-Tv", "S1", "S2b-i", "S2b-ii", "S2a"):
        resolve(rows, r, 1, None)
    try:
        resolve(rows, "S3", 1, None)
        raise AssertionError("S3 resolved without a resolution")
    except Unresolved as e:
        assert "HOST_TUNES=@probe-tune" in str(e), e
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
        f.write("origin\tcohort\tkey\tvalue\tsource\nS3\t1\tHOST_TUNES\tnone\tresults/g3/x/tables/tune-selection.tsv\n")
    try:
        assert resolve(rows, "S3", 1, f.name)["params"]["HOST_TUNES"] == "none"
        for rung, c in (("S3", 10), ("S4", 1)):
            try:
                resolve(rows, rung, c, f.name)
                raise AssertionError("%s resolved at c%d" % (rung, c))
            except Unresolved:
                pass
    finally:
        os.unlink(f.name)
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
    for r in ("S0-T1", "S1", "S2b-i", "S2b-ii", "S2a"):
        assert fits(resolve(rows, r, 1, None), 1, 1572864) == [], r
    assert fits(resolve(rows, "S2a", 1, None), 1, 524288)
    # manifest params from a spec's PARAMS block; other specs give none.
    sp = spec_params({"command": ["bash", "-c", "x\n" + PARAMS_MARK + " S S1 1):\n"
                                  "RUNG=S1; ARM=S; COHORT=1; WANT_N=1; THREADS=vcpus\ny\n"]})
    assert sp == {"rung": "S1", "arm": "S", "cohort": 1, "want_n": 1, "threads": "vcpus", "run_kind": "ladder",
                  "state": "cold", "source": "spec command[2] PARAMS block"}, sp
    assert spec_params({"command": ["bash", "-c", "# Parameters (scripts/g3/mkspec.sh):\nEXP=e1; COHORT=1\n"]}) is None
    assert spec_params({"command": ["bash", "-c"]}) is None
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
        if probs:
            print("ladder_levers: %d problem(s):\n  %s" % (len(probs), "\n  ".join(probs)), file=sys.stderr)
            return 1
        print("ladder_levers: %d rungs; every rung changes exactly one key-group" % len(rows))
        return 0
    if a and a[0] == "spec-params" and len(a) == 2:
        with open(a[1]) as f:
            print(json.dumps(spec_params(json.load(f)), separators=(",", ":")))
        return 0
    if a and a[0] == "params" and len(a) >= 3:
        return _params_main(a[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
