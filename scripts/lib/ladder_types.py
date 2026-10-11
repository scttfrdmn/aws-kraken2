#!/usr/bin/env python3
"""scripts/g3/ladder.types.tsv: the instance types O2 and O3 choose among (docs/ladder.md, "Candidate rungs").

  ladder_types.py write      query truffle (read-only: no launch) and write the table, with the truffle
                             version and the query time in its header
  ladder_types.py check      query truffle again and compare: exit 1 if any type, vCPU count, memory or
                             price differs from the committed table (the header's version and time are
                             reported, not compared)
  ladder_types.py validate   no AWS: the committed table's shape (make test): every family present, each
                             row a type of its family with positive vCPUs and memory, no duplicates

The families are those O2's rule names: c8g, c9g, r8g and x8g (not their d, b or n variants).
ladder_levers.py's floor rule (O3-n<K>'s host) reads the table; a metal type is listed but skipped there.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TSV = os.path.join(ROOT, "scripts", "g3", "ladder.types.tsv")
FAMILIES = ("c8g", "c9g", "r8g", "x8g")
REGION = "us-west-2"
HEAD = ["type", "vcpus", "memory_mib", "on_demand_usd_per_h"]


def truffle_version():
    r = subprocess.run(["truffle", "version"], capture_output=True, text=True)
    m = re.search(r"Version:\s*(\S+)", r.stdout + r.stderr)
    if r.returncode != 0 or not m:
        raise SystemExit("ladder_types: `truffle version` gave no version (rc %d): %s" % (r.returncode, (r.stdout + r.stderr)[-300:]))
    return m.group(1)


def query():
    args = ["truffle", "find"] + ["%s.*" % f for f in FAMILIES] + ["--regions", REGION, "--show-price", "-o", "json"]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("ladder_types: %s failed (rc %d): %s" % (" ".join(args), r.returncode, r.stderr[-300:]))
    try:
        d = json.loads(r.stdout)
    except ValueError as e:
        raise SystemExit("ladder_types: truffle gave no JSON (%s): %s" % (e, r.stdout[:300]))
    out = {}

    def walk(x):
        if isinstance(x, dict):
            if "on_demand_price" in x and "instance_type" in x:
                out[x["instance_type"]] = x
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(d)
    rows = {}
    for t, x in out.items():
        if t.split(".")[0] in FAMILIES:
            rows[t] = (int(x["vcpus"]), int(x["memory_mib"]), "%s" % x["on_demand_price"])
    return " ".join(args), rows


def order(t):
    fam, size = t.split(".")
    n = {"medium": 0, "large": 1}.get(size)
    if n is None:
        n = 2 + int(re.sub(r"\D", "", size) or 1)
    return (FAMILIES.index(fam) if fam in FAMILIES else 99, "metal" in size, n)


def render(rows, version, cmd, when):
    s = ("# Instance types of the families O2 and O3 choose among (c8g, c9g, r8g, x8g; %s), for ladder_levers.py's\n"
         "# floor rule: a family's smallest non-metal type that holds a rung by fits() (O3-n<K>'s host, Scott 2026-10-11, #25).\n"
         "# Written by make ladder-types (scripts/lib/ladder_types.py write): truffle %s, `%s`, %s.\n"
         "# A metal type has its twin's vCPUs, memory and price, so the floor skips it.\n" % (REGION, version, cmd, when))
    s += "\t".join(HEAD) + "\n"
    for t in sorted(rows, key=order):
        v, m, p = rows[t]
        s += "%s\t%d\t%d\t%s\n" % (t, v, m, p)
    return s


def read(path=TSV):
    rows, header = {}, []
    with open(path) as f:
        head = None
        for line in f:
            if line.startswith("#"):
                header.append(line.rstrip("\n"))
                continue
            if not line.strip():
                continue
            c = line.rstrip("\n").split("\t")
            if head is None:
                head = c
                if head != HEAD:
                    raise SystemExit("ladder_types: %s: columns %s, want %s" % (path, head, HEAD))
                continue
            if c[0] in rows:
                raise SystemExit("ladder_types: %s: %s listed twice" % (path, c[0]))
            rows[c[0]] = (int(c[1]), int(c[2]), c[3])
    return rows, header


def validate(path=TSV):
    rows, header = read(path)
    probs = []
    for t, (v, m, p) in rows.items():
        if t.split(".")[0] not in FAMILIES:
            probs.append("%s is not of the families %s" % (t, ", ".join(FAMILIES)))
        if v < 1 or m < 1:
            probs.append("%s: vcpus %d, memory_mib %d" % (t, v, m))
        try:
            float(p)
        except ValueError:
            probs.append("%s: price %r" % (t, p))
    for f in FAMILIES:
        if not any(t.split(".")[0] == f and "metal" not in t for t in rows):
            probs.append("no non-metal %s type" % f)
    if not any(re.search(r"truffle \S+, `truffle find", h) for h in header):
        probs.append("the header does not record the truffle version and query")
    return probs


def main(a):
    if a == ["validate"]:
        probs = validate()
        if probs:
            print("ladder_types: %s fails:\n  %s" % (os.path.relpath(TSV, ROOT), "\n  ".join(probs)), file=sys.stderr)
            return 1
        print("ladder_types: %s ok (%d types)" % (os.path.relpath(TSV, ROOT), len(read()[0])))
        return 0
    if a in (["write"], ["check"]):
        version = truffle_version()
        cmd, rows = query()
        for f in FAMILIES:
            if not any(t.split(".")[0] == f for t in rows):
                raise SystemExit("ladder_types: truffle returned no %s type; not written" % f)
        when = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if a == ["write"]:
            with open(TSV, "w") as f:
                f.write(render(rows, version, cmd, when))
            print("ladder_types: wrote %s: %d types (truffle %s)" % (os.path.relpath(TSV, ROOT), len(rows), version))
            print("ladder_types: scripts/g3/ is under run.sh's paths: commit the table before the next launch")
            return 0
        have, header = read()
        diff = sorted(set(have) ^ set(rows)) + sorted(t for t in set(have) & set(rows) if have[t] != rows[t])
        rec = [h for h in header if "truffle " in h]
        print("ladder_types: committed: %s" % (rec[0][2:] if rec else "no truffle version recorded"))
        print("ladder_types: now: truffle %s, %s" % (version, when))
        if diff:
            for t in diff:
                print("ladder_types: differs: %s: committed %s, truffle now %s" % (t, have.get(t, "absent"), rows.get(t, "absent")))
            print("ladder_types: %d type(s) differ: make ladder-types rewrites the table" % len(diff), file=sys.stderr)
            return 1
        print("ladder_types: the committed table equals truffle's answer (%d types)" % len(rows))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
