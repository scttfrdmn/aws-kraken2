#!/usr/bin/env python3
"""Refuse a spec script that turns errexit back on (CLAUDE.md Law 4: `set +e`).

Used by scripts/run.sh on command[2] of a spec. Reads the script on stdin and prints one line per
finding ("line N: <command>"); exits 1 if there are findings, 0 if there are none.

It tokenises the script like a shell, rather than matching one regex: quotes, backslashes,
comments, heredoc bodies and command separators are understood. It then inspects the option
words of every simple command:

  set     any -cluster containing e (-e, -eu, -xe, ...), or -o errexit, anywhere before -- or
          the first positional word: `set -u -e`, `set -o pipefail -e`, `set -o nounset -o errexit`
  shopt   -s together with -o (in any spelling: -so, -s -o, -os) and the name errexit
  bash/sh/dash/ksh/zsh   an option cluster containing e, or -o errexit; the -c string is re-checked
  eval    its arguments are joined and re-checked: eval "set -e"
  #!      a shebang carrying -e

Leading assignments (X=1) and the prefixes command/builtin/if/then/else/elif/do/while/until/!/
time are skipped. Quoted text and heredoc bodies are data, so `echo "set -e"` is not a finding.

Not covered (the preamble's runtime check of $- is the backstop): code inside "$(...)" within
double quotes, code reached through variables ($cmd -e), aliases, functions defined via eval of
computed strings, `source`d files, and BASH_ENV (refused separately by run.sh).

`--self-test` runs the built-in cases.
"""
import os
import re
import sys

SEP = ";"
SHELLS = {"bash", "sh", "dash", "ksh", "zsh"}
PREFIXES = {"command", "builtin", "if", "then", "else", "elif", "do", "while", "until", "!", "time", "{", "}"}


def tokenize(s):
    """Return [(word, line)] with SEP tokens between commands; heredoc bodies are skipped."""
    toks, cur, cur_line, line, i, n = [], None, 1, 1, 0, len(s)
    heredocs = []

    def flush():
        nonlocal cur
        if cur is not None:
            toks.append(("".join(cur), cur_line))
            cur = None

    def add(ch):
        nonlocal cur, cur_line
        if cur is None:
            cur, cur_line = [], line
        cur.append(ch)

    while i < n:
        c = s[i]
        if c == "\n":
            flush()
            toks.append((SEP, line))
            line += 1
            i += 1
            # Skip the bodies of heredocs opened on the line just ended.
            for delim, dash in heredocs:
                while i < n:
                    j = s.find("\n", i)
                    body_line = s[i:] if j < 0 else s[i:j]
                    i = n if j < 0 else j + 1
                    line += 1
                    if (body_line.lstrip("\t") if dash else body_line) == delim:
                        break
            heredocs = []
        elif c in " \t\r":
            flush()
            i += 1
        elif c == "#" and cur is None:
            while i < n and s[i] != "\n":
                i += 1
        elif c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                line += 1
            elif i + 1 < n:
                add(s[i + 1])
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            if cur is None:
                cur, cur_line = [], line
            cur.extend(s[i + 1:j])
            line += s.count("\n", i, j)
            i = j + 1
        elif c == "$" and i + 1 < n and s[i + 1] == "'":
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if cur is None:
                cur, cur_line = [], line
            cur.extend(s[i + 2:j].replace("\\'", "'"))
            line += s.count("\n", i, j)
            i = j + 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n and s[j + 1] in '"\\$`\n':
                    if s[j + 1] != "\n":
                        buf.append(s[j + 1])
                    j += 2
                else:
                    buf.append(s[j])
                    j += 1
            if cur is None:
                cur, cur_line = [], line
            cur.extend(buf)
            line += s.count("\n", i, j)
            i = j + 1
        elif s.startswith("<<<", i):
            flush()
            i += 3
        elif s.startswith("<<", i):
            flush()
            i += 2
            dash = i < n and s[i] == "-"
            if dash:
                i += 1
            while i < n and s[i] in " \t":
                i += 1
            m = re.match(r"""(['"]?)([^\s'"<>;&|()]+)\1""", s[i:])
            if m:
                heredocs.append((m.group(2), dash))
                i += m.end()
        elif c in ";&|()" or (c in "{}" and cur is None):
            flush()
            toks.append((SEP, line))
            i += 1
        else:
            add(c)
            i += 1
    flush()
    return toks


def commands(toks):
    cmd = []
    for w, ln in toks:
        if w == SEP:
            if cmd:
                yield cmd
            cmd = []
        else:
            cmd.append((w, ln))
    if cmd:
        yield cmd


def errexit_in_set(args):
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--", "-"):
            return False
        if a[:1] == "-" and len(a) > 1:
            if "e" in a[1:]:
                return True
            if "o" in a[1:]:
                if i + 1 < len(args) and args[i + 1] == "errexit":
                    return True
                i += 1
        elif a[:1] == "+" and len(a) > 1:
            if "o" in a[1:]:
                i += 1
        else:
            return False
        i += 1
    return False


def errexit_in_shopt(args):
    opts = "".join(a[1:] for a in args if a.startswith("-"))
    names = [a for a in args if not a.startswith("-")]
    return "s" in opts and "o" in opts and "errexit" in names


def check(src, base_line=0, depth=0):
    """Return a list of (line, text) findings."""
    out = []
    if depth > 5:
        return out
    if depth == 0:
        first = src.split("\n", 1)[0]
        if first.startswith("#!") and re.search(r"\s-[A-Za-z]*e", first):
            out.append((1, first))
    for cmd in commands(tokenize(src)):
        words = [w for w, _ in cmd]
        ln = cmd[0][1] + base_line
        k = 0
        while k < len(words) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k]) or words[k] in PREFIXES):
            k += 1
        if k >= len(words):
            continue
        name, args = os.path.basename(words[k]), words[k + 1:]
        text = " ".join(words[k:])
        if name == "set" and errexit_in_set(args):
            out.append((ln, text))
        elif name == "shopt" and errexit_in_shopt(args):
            out.append((ln, text))
        elif name == "eval":
            out += [(ln, f"eval: {t}") for _, t in check(" ".join(args), 0, depth + 1)]
        elif name in SHELLS:
            j = 0
            while j < len(args) and args[j][:1] in "-+" and len(args[j]) > 1:
                a = args[j]
                if a.startswith("--"):
                    j += 1
                    continue
                if a[0] == "-" and "e" in a[1:]:
                    out.append((ln, text))
                    break
                if "o" in a[1:]:
                    if a[0] == "-" and j + 1 < len(args) and args[j + 1] == "errexit":
                        out.append((ln, text))
                        break
                    j += 1
                if "c" in a[1:]:
                    # bash -c CODE: the next non-option word is code.
                    rest = [x for x in args[j + 1:] if not x.startswith("-")]
                    if rest:
                        out += [(ln, f"{name} -c: {t}") for _, t in check(rest[0], 0, depth + 1)]
                    break
                j += 1
    return out


SELF_TEST = [
    # (script, should_flag)
    ("set -e", True), ("set -euo pipefail", True), ("  set -o errexit", True),
    ("x=1; set -e", True), ("set -u -e", True), ("set -o pipefail -e", True),
    ("set -o nounset -o errexit", True), ('eval "set -e"', True), ("eval set -eu", True),
    ("shopt -s -o errexit", True), ("shopt -so errexit", True), ("shopt -os errexit", True),
    ("bash -e script.sh", True), ("bash -ce 'echo'", True), ("bash -c 'set -e; x'", True),
    ("/bin/sh -o errexit x.sh", True), ("#!/bin/bash -e\necho", True), ("if true; then set -e; fi", True),
    ("command set -e", True), ("(set -e)", True), ("x=$(set -e; echo)", True), ("{ set -e; }", True),
    ("set +e", False), ("set -- $AK2_DATASETS", False), ("set -o pipefail", False), ("set -x", False),
    ('echo "reset -e"', False), ('echo "set -e"', False), ("echo 'set -o errexit'", False),
    ("cat <<EOF\nset -e\nEOF\necho ok", False), ("cat <<-'X'\n\tset -e\n\tX\n", False),
    ("# set -e in a comment", False), ("shopt -o errexit", False), ("shopt -u -o errexit", False),
    ("set +o errexit", False), ("bash -c 'echo -e x'", False), ("grep -e set f", False),
    ("set -- -e", False), ("ak2_say \"don't set -e\"", False), ("x=1 # set -e", False),
    ("cat <<EOF\nset -e\nEOF\nset -e", True),
]


def self_test():
    bad = 0
    for src, want in SELF_TEST:
        got = bool(check(src))
        if got != want:
            bad += 1
            print(f"FAIL: {src!r}: got {got}, want {want}: {check(src)}")
    print(f"errexit_check self-test: {len(SELF_TEST) - bad}/{len(SELF_TEST)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    findings = check(sys.stdin.read())
    for ln, text in findings:
        print(f"line {ln}: {text}")
    sys.exit(1 if findings else 0)
