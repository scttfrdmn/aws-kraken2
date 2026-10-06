#!/usr/bin/env python3
"""One timed classifier run for make loadbench (docs/loadbench.md, issue #36).

Usage: lbrun.py STDERR_FILE -- CMD ARGS...

Runs CMD with stdout to /dev/null (pass --output) and its stderr captured, and prints one JSON
object on stdout. Every number is measured here with the same instrument for upstream and for
ours, so the two are comparable:

  wall_s      exec to exit (t0 is taken immediately before the fork)
  load_s      t0 to the arrival of " done." after "Loading database information..." on stderr:
              startup (including upstream's Perl wrapper) plus the opts/taxo/hash loads
  classify_s  the "processed in X s" figure the classifier itself prints
  tail_s      the arrival of the "processed" line to exit: report, final flushes, teardown
  minflt, majflt, user_s, sys_s, maxrss_kib  getrusage(RUSAGE_CHILDREN) deltas (the whole
              process tree; ru_maxrss is the largest child, in KiB on Linux, bytes on macOS)

stderr arrives through a pipe that is read with os.read as it is written; upstream writes it
unbuffered (std::cerr), ours unbuffered (os.Stderr), so a line's arrival time is its write time
to within the read loop's latency (microseconds). Lines starting with "ak2-timing" (ours, with
AK2_TIMINGS=1) are passed through to STDERR_FILE untouched.
"""
import json
import os
import re
import resource
import subprocess
import sys
import time

TIMING = re.compile(rb"ak2-timing\t[^\n]*\n")


def main():
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[1] != "--":
        sys.exit("usage: lbrun.py STDERR_FILE -- CMD ARGS...")
    errfile, cmd = argv[0], argv[2:]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE)
    fd = p.stderr.fileno()
    buf = b""
    t_done = t_stats = None
    while True:
        chunk = os.read(fd, 65536)
        now = time.monotonic()
        if not chunk:
            break
        buf += chunk
        # Ours with AK2_TIMINGS=1 writes its phase lines between "..." and " done.".
        if t_done is None and b"Loading database information... done." in TIMING.sub(b"", buf):
            t_done = now
        if t_stats is None and re.search(rb"sequences \([0-9.]+ Mbp\) processed in", buf):
            t_stats = now
    rc = p.wait()
    t1 = time.monotonic()
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    with open(errfile, "wb") as f:
        f.write(buf)
    m = re.search(rb"processed in ([0-9.]+)s", buf)
    rnd = lambda x: None if x is None else round(x, 6)
    out = {
        "exit": rc,
        "wall_s": rnd(t1 - t0),
        "load_s": rnd(None if t_done is None else t_done - t0),
        "classify_s": float(m.group(1)) if m else None,
        "tail_s": rnd(None if t_stats is None else t1 - t_stats),
        "minflt": after.ru_minflt - before.ru_minflt,
        "majflt": after.ru_majflt - before.ru_majflt,
        "user_s": rnd(after.ru_utime - before.ru_utime),
        "sys_s": rnd(after.ru_stime - before.ru_stime),
        "maxrss": after.ru_maxrss,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
