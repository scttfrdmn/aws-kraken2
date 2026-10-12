#!/usr/bin/env python3
"""The ladder body's compatibility declarations (scripts/g3/ladder.body-compat.tsv; docs/ladder.md,
"Body changes and finished runs").

Every ladder spec embeds scripts/g3/ladder.body.sh in command[2], with the rung's parameter block in
place of its @PARAMS@ line. So any change to the body changes every spec's sha256, and
ladder-campaign's done check would rerun every finished run, including runs on arms the change
cannot affect. A row of the TSV declares that one body version (from_body_sha256) and the next
(to_body_sha256) behave the same for the classifiers in `unaffected`. The campaign then counts a
finished run whose spec differs from the committed spec in nothing but the body, where a chain of
rows from the run's body to the committed body covers the run's classifier (verdict()). Everything
else in the spec, including the parameter block, must be byte-identical.

A row is checked mechanically (`check`):
  - both body sha256s are versions of ladder.body.sh in git history (or the working tree), and
    `commit` holds the `to` version;
  - unaffected and affected are disjoint, and together they are every classifier;
  - every changed line lies inside the block that scripts/tests/ladder_stream_test.sh drives
    (between its "load and classify" and "end of the functions" markers), inside the functions
    the row names. Case X of that test then runs both versions for every classifier: the
    classifier invocations (argv and AK2_* env) must be identical for each unaffected classifier
    and must differ for each affected one.

  ladder_body_compat.py check [TSV]        validate every row; print each row's hunks and their functions
  ladder_body_compat.py diff OLD NEW       what differs between two ladder specs: exit 0 if identical
                                           or body-only, 1 if anything else differs
  ladder_body_compat.py body-at SHA256     print the body version with that sha256 (from git history)
  ladder_body_compat.py rows [TSV]         from, to, unaffected and affected, tab-separated (for the test)
  ladder_body_compat.py fresh              every committed ladder spec embeds the current body
  ladder_body_compat.py --self-test        check() refuses bad rows
"""
import difflib
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True
BODY = "scripts/g3/ladder.body.sh"
TSV = os.path.join(ROOT, "scripts", "g3", "ladder.body-compat.tsv")
CLASSIFIERS = ("upstream", "ours-plain", "ours-engine")
COLUMNS = ["from_body_sha256", "to_body_sha256", "commit", "unaffected", "affected", "functions", "reason"]
PARAMS_MARK = "# Parameters (scripts/g3/mkspec-ladder.sh"
TTL_MARK = "# TTL "
BLOCK_START = "# ---- load and classify"
BLOCK_END = "# ---- end of the functions"
SHA_RE = re.compile(r"[0-9a-f]{64}")
FN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{")


def sha256(b):
    return hashlib.sha256(b if isinstance(b, bytes) else b.encode()).hexdigest()


def git(*a):
    return subprocess.run(["git", "-C", ROOT] + list(a), capture_output=True)


# ---------------------------------------------------------------- specs

def split_spec(spec):
    """(rest, params_block, body): the spec without command[2], the three lines mkspec-ladder.sh put in
    place of @PARAMS@ (TTL note, header, PARAMS), and the body text as ladder.body.sh holds it. None if
    the spec is not a ladder spec."""
    try:
        c2 = spec["command"][2]
    except (KeyError, IndexError, TypeError):
        return None
    lines = c2.split("\n")
    idx = [i for i, l in enumerate(lines) if l.startswith(PARAMS_MARK)]
    if len(idx) != 1:
        return None
    i = idx[0]
    if i < 1 or i + 1 >= len(lines) or not lines[i - 1].startswith(TTL_MARK):
        return None
    rest = json.loads(json.dumps(spec))
    rest["command"][2] = None
    # mkspec-ladder.sh takes the body through $(...), which drops its final newline.
    body = "\n".join(lines[:i - 1] + ["@PARAMS@"] + lines[i + 2:]) + "\n"
    return rest, lines[i - 1:i + 2], body


def spec_diff(a, b):
    """(kind, details): kind 'identical', 'body' (only the body differs: details (from_sha, to_sha)),
    or 'other' (details: what else differs)."""
    if a == b:
        return "identical", None
    sa, sb = split_spec(a), split_spec(b)
    if sa is None or sb is None:
        return "other", ["not a ladder spec (no single parameter block after a TTL note in command[2])"]
    other = []
    if sa[0] != sb[0]:
        ka, kb = flat(sa[0]), flat(sb[0])
        for k in sorted(set(ka) | set(kb)):
            if ka.get(k) != kb.get(k):
                other.append("%s: %s != %s" % (k, json.dumps(ka.get(k)), json.dumps(kb.get(k))))
    if sa[1] != sb[1]:
        for x, y in zip(sa[1], sb[1]):
            if x != y:
                other.append("parameter block: %r != %r" % (x[:120], y[:120]))
    if other:
        return "other", other
    return "body", (sha256(sa[2]), sha256(sb[2]))


def flat(o, p=""):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            out.update(flat(v, "%s.%s" % (p, k) if p else k))
        return out
    if isinstance(o, list):
        out = {}
        for i, v in enumerate(o):
            out.update(flat(v, "%s[%d]" % (p, i)))
        return out
    return {p: o}


# ---------------------------------------------------------------- the declarations

def load(path=TSV):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path) as f:
        head = None
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cells = line.split("\t")
            if head is None:
                head = cells
                if head != COLUMNS:
                    raise SystemExit("ladder_body_compat: %s: header %s, want %s" % (path, head, COLUMNS))
                continue
            if len(cells) != len(COLUMNS):
                raise SystemExit("ladder_body_compat: %s line %d: %d columns, want %d" % (path, n, len(cells), len(COLUMNS)))
            r = dict(zip(COLUMNS, cells))
            r["line"] = n
            for k in ("unaffected", "affected", "functions"):
                r[k] = [x for x in r[k].split(",") if x]
            rows.append(r)
    return rows


def chain(rows, frm, to, classifier):
    """The rows leading from body frm to body to, each covering classifier; None if there is none."""
    if frm == to:
        return []
    seen, todo = {frm}, [(frm, [])]
    while todo:
        cur, path = todo.pop(0)
        for r in rows:
            if r["from_body_sha256"] == cur and classifier in r["unaffected"] and r["to_body_sha256"] not in seen:
                p = path + [r]
                if r["to_body_sha256"] == to:
                    return p
                seen.add(r["to_body_sha256"])
                todo.append((r["to_body_sha256"], p))
    return None


def verdict(run_spec, committed_spec, classifier, rows=None):
    """(ok, note) for a finished run whose spec is not the committed one: ok when the two differ only
    in the body and ladder.body-compat.tsv covers that body pair for the run's classifier."""
    kind, det = spec_diff(run_spec, committed_spec)
    if kind == "identical":
        return True, "spec identical"
    if kind == "other":
        return False, "spec differs beyond the body: " + "; ".join(det[:3])
    rows = load() if rows is None else rows
    c = chain(rows, det[0], det[1], classifier)
    if c is None:
        return False, "spec differs only in the body (%s -> %s), and ladder.body-compat.tsv does not declare that change harmless for %s" % (
            det[0][:12], det[1][:12], classifier)
    return True, "spec differs only in the body (%s -> %s); ladder.body-compat.tsv line(s) %s: %s unaffected" % (
        det[0][:12], det[1][:12], ",".join(str(r["line"]) for r in c), classifier)


# ---------------------------------------------------------------- git history and the check

def versions():
    """{sha256: (commit or 'worktree', text)} of every version of the body in git history."""
    out = {}
    p = os.path.join(ROOT, BODY)
    if os.path.isfile(p):
        with open(p, "rb") as f:
            b = f.read()
        out[sha256(b)] = ("worktree", b.decode())
    r = git("log", "--all", "--format=%H", "--", BODY)
    for h in r.stdout.decode().split():
        s = git("show", "%s:%s" % (h, BODY))
        if s.returncode == 0:
            out[sha256(s.stdout)] = (h, s.stdout.decode())
    return out


def regions(text):
    """Per line (0-based): (in the stream-test block, enclosing function or None)."""
    lines = text.split("\n")
    out, inblock, fn = [], False, None
    for l in lines:
        if l.startswith(BLOCK_START):
            inblock = True
        m = FN_RE.match(l)
        if m:
            fn = m.group(1)
            out.append((inblock, fn))
            if l.rstrip().endswith("}"):
                fn = None
            continue
        out.append((inblock, fn))
        if fn and l == "}":
            fn = None
        if l.startswith(BLOCK_END):
            inblock = False
    return out


def hunks(a, b):
    """[(header, changed: [(side, lineno, text, in_block, function)])] of the diff a -> b."""
    la, lb = a.split("\n"), b.split("\n")
    ra, rb = regions(a), regions(b)
    out = []
    sm = difflib.SequenceMatcher(None, la, lb, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        ch = [("-", i + 1, la[i]) + ra[i] for i in range(i1, i2)] + [("+", j + 1, lb[j]) + rb[j] for j in range(j1, j2)]
        if tag == "insert" and j1 > 0:
            # a pure insertion inside a function: the line before it says where
            ch = [c if c[4] else c[:3] + rb[j1 - 1] for c in ch]
        out.append(("@@ -%d,%d +%d,%d @@" % (i1 + 1, i2 - i1, j1 + 1, j2 - j1), ch))
    return out


def check(path=TSV, out=print):
    rows, vs, bad = load(path), versions(), 0
    for r in rows:
        probs = []
        f, t = r["from_body_sha256"], r["to_body_sha256"]
        for k in ("from_body_sha256", "to_body_sha256"):
            if not SHA_RE.fullmatch(r[k]):
                probs.append("%s %r is not a sha256" % (k, r[k]))
        cl = r["unaffected"] + r["affected"]
        if sorted(cl) != sorted(CLASSIFIERS) or len(set(cl)) != len(cl):
            probs.append("unaffected %s and affected %s must split %s" % (r["unaffected"], r["affected"], ",".join(CLASSIFIERS)))
        if not r["unaffected"]:
            probs.append("no unaffected classifier: the row declares nothing")
        if not r["reason"].strip():
            probs.append("no reason")
        for s in (f, t):
            if s not in vs:
                probs.append("body %s is not a version of %s in git history" % (s[:12], BODY))
        cs = git("show", "%s:%s" % (r["commit"], BODY))
        if cs.returncode != 0:
            probs.append("commit %s has no %s" % (r["commit"], BODY))
        elif sha256(cs.stdout) != t:
            probs.append("the body at commit %s is %s, not to_body_sha256 %s" % (r["commit"], sha256(cs.stdout)[:12], t[:12]))
        out("ladder_body_compat: line %d: %s -> %s (commit %s): unaffected %s; affected %s; %s" % (
            r["line"], f[:12], t[:12], r["commit"][:12], ",".join(r["unaffected"]), ",".join(r["affected"]), r["reason"]))
        if f in vs and t in vs:
            hs = hunks(vs[f][1], vs[t][1])
            if not hs:
                probs.append("the two versions are identical")
            for hdr, ch in hs:
                fns = sorted({c[4] or "<top level>" for c in ch})
                out("  %s in %s" % (hdr, ", ".join(fns)))
                for side, n, text, inblock, fn in ch:
                    out("    %s%5d %s" % (side, n, text))
                    if not inblock:
                        probs.append("%s line %d is outside the block ladder_stream_test.sh drives, so case X cannot probe it" % (side, n))
                    elif fn not in r["functions"]:
                        probs.append("%s line %d is in %s, not in the row's functions %s" % (side, n, fn or "<top level>", ",".join(r["functions"])))
        for p in probs:
            out("  PROBLEM: %s" % p)
        bad += bool(probs)
    out("ladder_body_compat: %d row(s), %d with problems" % (len(rows), bad))
    return 1 if bad else 0


def fresh(out=print):
    """Every committed ladder spec embeds the current body (else: make ladder-respec)."""
    import glob
    cur = sha256(open(os.path.join(ROOT, BODY), "rb").read())
    stale = []
    for f in sorted(glob.glob(os.path.join(ROOT, "runs", "g3-l-*.json"))):
        with open(f) as fh:
            sp = split_spec(json.load(fh))
        if sp is None:
            stale.append("%s: no parameter block" % os.path.relpath(f, ROOT))
        elif sha256(sp[2]) != cur:
            stale.append("%s embeds body %s, not the current %s" % (os.path.relpath(f, ROOT), sha256(sp[2])[:12], cur[:12]))
    for x in stale:
        out("ladder_body_compat: STALE %s (make ladder-respec)" % x)
    out("ladder_body_compat: %d stale spec(s)" % len(stale))
    return 1 if stale else 0


def self_test():
    """check() refuses a row whose changes leave its functions, a wrong to sha, and a classifier split
    that is not a partition; and passes the committed rows."""
    import tempfile
    rows = load()
    if not rows:
        print("ladder_body_compat: self-test: no committed rows")
        return 1
    r = rows[0]
    fails = 0

    def run(cells, want, what):
        nonlocal fails
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
            f.write("\t".join(COLUMNS) + "\n" + "\t".join(cells) + "\n")
        got = check(f.name, out=lambda l: None)
        os.unlink(f.name)
        ok = got == want
        fails += not ok
        print("ladder_body_compat: self-test %s %s" % ("ok  " if ok else "FAIL", what))

    base = [r["from_body_sha256"], r["to_body_sha256"], r["commit"], ",".join(r["unaffected"]), ",".join(r["affected"]),
            ",".join(r["functions"]), r["reason"]]
    run(base, 0, "the committed row passes")
    run(base[:5] + ["lad_engine"] + base[6:], 1, "changes outside the row's functions are refused")
    run([base[0], base[0]] + base[2:], 1, "a to sha that is not the body at the commit is refused")
    run(base[:4] + [""] + base[5:], 1, "unaffected and affected that do not cover every classifier are refused")
    return 1 if fails else 0


def main(a):
    if not a:
        print(__doc__)
        return 2
    if a[0] == "fresh":
        return fresh()
    if a[0] == "--self-test":
        return self_test()
    if a[0] == "check":
        return check(a[1] if len(a) > 1 else TSV)
    if a[0] == "diff" and len(a) == 3:
        with open(a[1]) as f:
            x = json.load(f)
        with open(a[2]) as f:
            y = json.load(f)
        kind, det = spec_diff(x, y)
        if kind == "identical":
            print("ladder_body_compat: %s: identical" % a[2])
            return 0
        if kind == "body":
            print("ladder_body_compat: %s: only the body differs (%s -> %s)" % (a[2], det[0][:12], det[1][:12]))
            return 0
        print("ladder_body_compat: %s: differs beyond the body:" % a[2])
        for d in det:
            print("  " + d)
        return 1
    if a[0] == "body-at" and len(a) == 2:
        v = versions().get(a[1])
        if v is None:
            print("ladder_body_compat: no body version %s" % a[1], file=sys.stderr)
            return 1
        sys.stdout.write(v[1])
        return 0
    if a[0] == "rows":
        for r in load(a[1] if len(a) > 1 else TSV):
            print("\t".join([r["from_body_sha256"], r["to_body_sha256"], ",".join(r["unaffected"]), ",".join(r["affected"])]))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
