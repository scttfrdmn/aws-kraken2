#!/usr/bin/env python3
"""make test: util.py runs after the last manifest write (#58). util.json records the sha256 of the
manifest util.py read; a manifest write after the call leaves util.json citing a manifest that no
longer exists. Checked statically on the three callers:

  scripts/run.sh         every `mset` call and the spec's post script (scripts/post/<spec>.sh,
                         which may write the manifest: g0c-runs.sh does) come before util.py
  scripts/refinalise.sh  every write into "$M" comes before util.py
  scripts/run-multi.sh   cohort.json is written before util.py; the cohort post scripts that run
                         after it (scripts/post/*.cohort.sh) write no manifest.json or cohort.json

The checker is shown to flag the order run.sh had before the fix (a self-test on a synthetic
script, and on run.sh at e095aa8 if git has it)."""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAIL = []

UTIL = re.compile(r"^\s*python3\s+scripts/lib/util\.py\b")
# A write into the manifest (or cohort.json): an mset call, or mv / > whose target is one.
TARGET = r'"?(\$\{?M\}?|\$\{?(M|MAN|MANIFEST)\}?|[^"\s]*(manifest|cohort)\.json)"?'
WRITES = [re.compile(r"^\s*mset\s"),
          re.compile(r"\bmv\s+(-\S+\s+)*\S+\s+" + TARGET + r"\s*(\|\||&&|;|$|\))"),
          re.compile(r"(?<![0-9&])>\s*" + TARGET + r"(\s|$|\|\||&&|;)"),
          re.compile(r'^\s*bash\s+"\$POST"')]


def code(text):
    """(line number, line) without comments or the mset() definition."""
    out = []
    for i, ln in enumerate(text.splitlines(), 1):
        s = ln.split("#", 1)[0] if not ln.lstrip().startswith("#") else ""
        if s.strip() and not re.match(r"^\s*mset\s*\(\)", s):
            out.append((i, s))
    return out


def order(text):
    """(util.py call lines, write lines after the last of them)."""
    lines = code(text)
    calls = [i for i, s in lines if UTIL.search(s)]
    if not calls:
        return calls, []
    return calls, [(i, s.strip()) for i, s in lines if i > calls[-1] and any(w.search(s) for w in WRITES)]


def check(name, cond, detail=""):
    print(f"util_order_test: {'ok  ' if cond else 'FAIL'} {name}{': ' + detail if detail else ''}")
    if not cond:
        FAIL.append(name)


def read(p):
    with open(os.path.join(ROOT, p)) as f:
        return f.read()


# Self-tests: the checker sees a write after the call, and none before it.
bad = 'mset() { :; }\npython3 scripts/lib/util.py "$D" > x\nmset --arg a b \'.a = $a\'\n'
check("self-test: an mset after util.py is flagged", len(order(bad)[1]) == 1, repr(order(bad)[1]))
bad = 'python3 scripts/lib/util.py "$D"\nTMP=$(mktemp) && jq . "$M" > "$TMP" && mv "$TMP" "$M" || x\n'
check("self-test: an mv into $M after util.py is flagged", len(order(bad)[1]) == 1, repr(order(bad)[1]))
good = 'mset .a\nbash "$POST" "$D"\n# mset in a comment\npython3 scripts/lib/util.py "$D" > "$D/tables/util.log"\nexit 0\n'
check("self-test: writes before util.py pass", order(good) == ([4], []), repr(order(good)))
try:
    old = subprocess.run(["git", "show", "e095aa8:scripts/run.sh"], cwd=ROOT, capture_output=True, text=True, timeout=20)
    if old.returncode == 0:
        w = order(old.stdout)[1]
        check("self-test: run.sh at e095aa8 (before the fix) is flagged", any("orphan_check" in s for _, s in w)
              and any("POST" in s for _, s in w), repr(w))
except (OSError, subprocess.SubprocessError):
    pass

for p in ("scripts/run.sh", "scripts/refinalise.sh", "scripts/run-multi.sh"):
    calls, after = order(read(p))
    check(f"{p} calls util.py", bool(calls), str(calls))
    check(f"{p}: no manifest write after util.py (line {calls[-1] if calls else '-'})", calls and not after, repr(after))

rm = read("scripts/run-multi.sh")
calls = [i for i, s in code(rm) if UTIL.search(s)]
cj = [i for i, s in code(rm) if re.search(r'>\s*"\$CDIR/cohort\.json"', s)]
check("run-multi.sh writes cohort.json before util.py", bool(cj) and bool(calls) and max(cj) < min(calls), f"cohort.json {cj}, util.py {calls}")
for p in sorted(glob.glob(os.path.join(ROOT, "scripts", "post", "*.cohort.sh"))):
    w = [(i, s.strip()) for i, s in code(open(p).read()) if any(x.search(s) for x in WRITES[1:3])]
    check(f"{os.path.relpath(p, ROOT)} writes no manifest.json or cohort.json (it runs after util.py)", not w, repr(w))

print("util_order_test:", "FAILED " + ", ".join(FAIL) if FAIL else "all ok")
sys.exit(1 if FAIL else 0)
