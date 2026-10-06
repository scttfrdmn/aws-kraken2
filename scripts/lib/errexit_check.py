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

Leading assignments (X=1), the prefixes command/builtin/if/then/else/elif/do/while/until/!/time,
and the wrappers exec, env (with its options and VAR=val words), sudo (with its options),
timeout [opts] DURATION, nohup, nice [-n N], xargs [opts] and stdbuf [opts] are skipped before the
command name, so `sudo -u x bash -e`, `env -i A=1 sh -e` and `timeout 5 bash -e` are findings.
Quoted text, heredoc bodies and arithmetic ($((a << 2)), ((x <<= 1))) are data, so
`echo "set -e"` is not a finding and `<<` inside arithmetic does not open a heredoc.

Exit status: 0 no findings, 1 findings, 2 the checker itself failed (run.sh reports a crash).

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
# Wrappers that run their trailing words as a command: name -> options that take a value.
WRAPPERS = {
    "exec": {"-a"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-T", "-U", "--user", "--group",
             "--chdir", "--host", "--prompt", "--role", "--type", "--command-timeout", "--other-user"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nohup": set(),
    "nice": {"-n", "--adjustment"},
    "xargs": {"-a", "-d", "-E", "-e", "-I", "-i", "-L", "-l", "-n", "-P", "-s", "--arg-file",
              "--delimiter", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs",
              "--max-chars", "--process-slot-var"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "command": set(),
    "builtin": set(),
}


def skip_prefix(words, k):
    """Index of the real command name after assignments, keywords and wrappers."""
    while k < len(words):
        w = words[k]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w) or w in PREFIXES - {"command", "builtin"}:
            k += 1
            continue
        name = os.path.basename(w)
        if name not in WRAPPERS:
            return k
        takes = WRAPPERS[name]
        k += 1
        while k < len(words):
            a = words[k]
            if a == "--":
                k += 1
                break
            if name == "env" and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
                k += 1
            elif a.startswith("-") and len(a) > 1:
                opt = a.split("=", 1)[0]
                # -n5 / --signal=TERM carry their value; "-n 5" takes the next word.
                k += 2 if (opt in takes and "=" not in a and a == opt) else 1
            else:
                break
        if name == "timeout" and k < len(words):
            k += 1  # DURATION
    return k


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
        elif s.startswith("$((", i) or (s.startswith("((", i) and cur is None):
            # Arithmetic: copy through the matching "))" as data, so "<<" here is a shift.
            j, depth = i + (2 if s[i] == "(" else 3), 2
            while j < n and depth:
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 1
            if cur is None:
                cur, cur_line = [], line
            cur.extend(s[i:j])
            line += s.count("\n", i, j)
            i = j
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
        k = skip_prefix(words, 0)
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
    # wrappers before the shell name
    ("exec bash -e x.sh", True), ("env -i A=1 B=2 bash -e x", True), ("env -u HOME sh -e x", True),
    ("sudo bash -e x", True), ("sudo -u root -E bash -ec 'y'", True), ("sudo -- sh -o errexit x", True),
    ("timeout 5 bash -e x", True), ("timeout -s KILL -k 3 10m bash -e x", True), ("nohup sh -e x &", True),
    ("nice -n 5 bash -e x", True), ("nice bash -e x", True), ("echo f | xargs -n1 -P4 bash -e", True),
    ("stdbuf -oL bash -e x", True), ("stdbuf -o L sh -e x", True), ("command -p bash -e x", True),
    ("sudo timeout 5 env A=1 bash -e x", True), ("env bash -c 'set -e'", True),
    ("sudo -u root aws s3 ls", False), ("timeout 5 sleep 1", False), ("env A=1 printenv", False),
    ("xargs -n1 echo -e", False), ("nice -n 5 make -e", False),
    # arithmetic is not a heredoc
    ("x=$((1 << 4))\nset -e", True), ("((x <<= 1))\nset -e", True), ("echo $((a<<b)); echo ok", False),
    ("y=$(( (1 << 2) + 1 ))\ncat <<EOF\nset -e\nEOF", False),
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


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if os.environ.get("AK2_ERREXIT_CHECK_CRASH_TEST") == "1":
        raise RuntimeError("induced crash (AK2_ERREXIT_CHECK_CRASH_TEST)")
    findings = check(sys.stdin.read())
    for ln, text in findings:
        print(f"line {ln}: {text}")
    return 1 if findings else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # any checker bug must read as a crash, never as a verdict
        print(f"errexit_check crashed: {type(e).__name__}: {e}")
        sys.exit(2)
