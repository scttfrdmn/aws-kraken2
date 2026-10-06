#!/usr/bin/env python3
"""One instrumented classifier run for make g2 (docs/g2.md, issues #21-#23).

Usage: g2run.py --out PREFIX --threads T [--devs a,b] [--perf-events E1,E2] [--hz N]
                [--timeout S] -- CMD ARGS...

Runs CMD (upstream's kraken2 wrapper, which execs classify in the same pid) with stdout to
/dev/null and stderr captured to PREFIX.stderr, and prints one JSON object on stdout. Timing is
the same instrument as scripts/lib/lbrun.py:

  wall_s      t0 (just before the fork) to exit
  load_s      t0 to the arrival of "Loading database information... done."
  classify_s  the "processed in X s" figure the classifier prints
  tail_s      that line's arrival to exit

The classify window is the interval from "done." to the "processed" line. Over that window only:

  vmstat      /proc/vmstat deltas (pgmajfault, pgfault, pgpgin, workingset_refault_file, thp_*)
  disks       /proc/diskstats deltas per --devs device: read IOs, read bytes, aqu_sz
              (= delta time_in_queue / window, iostat's aqu-sz), util, mean read size
  perf        if --perf-events: `perf stat -D -1 --control fifo:...` launched as CMD's parent,
              enabled at "done." and disabled at "processed", so the counters cover the window
  sampler     every 1/--hz s, the state of every thread of CMD (/proc/PID/task/*/stat) and its
              current syscall (/proc/PID/task/*/syscall): R, D (uninterruptible: page-fault or
              block I/O), S in futex, S in read, S other; plus the same for CMD's child
              processes (the wrapper's `gzip -dc` decompressors)

Derived: offcpu_frac = 1 - task-clock / (threads x window); ipc; dTLB miss ratio;
disk_bytes_per_majfault (read-around amplification is disk bytes >> 4 KiB x pgmajfault).
getrusage(RUSAGE_CHILDREN) deltas cover the whole run. --timeout kills the run's process group
after S seconds and sets "timed_out": true (classify_s is then null: a censored rung).
Linux-only counters degrade to null elsewhere (macOS smoke tests).
"""
import argparse
import json
import os
import re
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time

FUTEX = {"arm64": 98, "aarch64": 98, "x86_64": 202}
READ = {"arm64": 63, "aarch64": 63, "x86_64": 0}
WRITE = {"arm64": 64, "aarch64": 64, "x86_64": 1}
VMKEYS = ("pgmajfault", "pgfault", "pgpgin", "workingset_refault_file", "thp_fault_alloc",
          "thp_fault_fallback", "thp_file_mapped", "pgscan_kswapd", "pgsteal_kswapd")


def vmstat():
    try:
        d = {}
        with open("/proc/vmstat") as f:
            for line in f:
                k, v = line.split()
                if k in VMKEYS:
                    d[k] = int(v)
        return d
    except OSError:
        return None


def diskstats(devs):
    out = {}
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                if len(p) >= 14 and p[2] in devs:
                    out[p[2]] = {"rd_ios": int(p[3]), "rd_sectors": int(p[5]), "rd_ticks": int(p[6]),
                                 "io_ticks": int(p[12]), "time_in_queue": int(p[13])}
    except OSError:
        return None
    return out


class Sampler(threading.Thread):
    def __init__(self, pid, hz, arch):
        super().__init__(daemon=True)
        self.pid, self.dt, self.stop = pid, 1.0 / hz, threading.Event()
        self.futex, self.read, self.write = FUTEX.get(arch, -1), READ.get(arch, -1), WRITE.get(arch, -1)
        self.n = 0
        self.thr = {"R": 0, "D": 0, "S_futex": 0, "S_read": 0, "S_other": 0, "other": 0}
        self.kids = {"R": 0, "D": 0, "S_write": 0, "S_other": 0, "other": 0}
        self.max_threads = 0

    def state(self, base):
        try:
            with open(base + "/stat") as f:
                s = f.read()
            st = s[s.rindex(")") + 2]
        except (OSError, ValueError, IndexError):
            return None, None
        sc = None
        if st == "S":
            try:
                with open(base + "/syscall") as f:
                    t = f.read().split()
                sc = int(t[0]) if t and t[0].lstrip("-").isdigit() else None
            except OSError:
                pass
        return st, sc

    def run(self):
        root = "/proc/%d" % self.pid
        while not self.stop.is_set():
            try:
                tids = os.listdir(root + "/task")
            except OSError:
                break
            self.n += 1
            self.max_threads = max(self.max_threads, len(tids))
            for t in tids:
                st, sc = self.state("%s/task/%s" % (root, t))
                if st is None:
                    continue
                if st in ("R", "D"):
                    self.thr[st] += 1
                elif st == "S":
                    k = "S_futex" if sc == self.futex else "S_read" if sc == self.read else "S_other"
                    self.thr[k] += 1
                else:
                    self.thr["other"] += 1
            try:
                with open("%s/task/%d/children" % (root, self.pid)) as f:
                    kids = f.read().split()
            except OSError:
                kids = []
            for k in kids:
                st, sc = self.state("/proc/" + k)
                if st is None:
                    continue
                if st in ("R", "D"):
                    self.kids[st] += 1
                elif st == "S":
                    self.kids["S_write" if sc == self.write else "S_other"] += 1
                else:
                    self.kids["other"] += 1
            self.stop.wait(self.dt)


def parse_perf(path):
    """perf stat -x, output: value,unit,event,run_time,pct,..."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                p = line.strip().split(",")
                if len(p) < 3:
                    continue
                try:
                    v = float(p[0])
                except ValueError:
                    v = None  # <not supported> / <not counted>
                out[p[2]] = v
    except OSError:
        return None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--threads", type=int, required=True)
    ap.add_argument("--devs", default="")
    ap.add_argument("--perf-events", default="")
    ap.add_argument("--perf", default="perf")
    ap.add_argument("--hz", type=float, default=20.0)
    ap.add_argument("--timeout", type=float, default=0.0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        sys.exit("g2run.py: no command")
    devs = [d for d in a.devs.split(",") if d]
    arch = os.uname().machine
    perf_out = ctl = ack = None
    tmpd = tempfile.mkdtemp(prefix="g2run.")
    if a.perf_events:
        perf_out = a.out + ".perf.csv"
        ctl, ack = os.path.join(tmpd, "ctl"), os.path.join(tmpd, "ack")
        os.mkfifo(ctl)
        os.mkfifo(ack)
        cmd = [a.perf, "stat", "-x", ",", "-o", perf_out, "-D", "-1",
               "--control", "fifo:%s,%s" % (ctl, ack), "-e", a.perf_events, "--"] + cmd

    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, start_new_session=True)
    ctl_fd = ack_fd = None
    if ctl:
        ctl_fd = os.open(ctl, os.O_WRONLY)   # blocks until perf opens it (at startup)
        ack_fd = os.open(ack, os.O_RDONLY)

    def perf_cmd(word):
        if ctl_fd is None:
            return
        try:
            os.write(ctl_fd, (word + "\n").encode())
            os.read(ack_fd, 64)
        except OSError:
            pass

    timed_out = [False]

    def killer():
        timed_out[0] = True
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    timer = threading.Timer(a.timeout, killer) if a.timeout > 0 else None
    if timer:
        timer.daemon = True
        timer.start()

    fd = p.stderr.fileno()
    buf = b""
    t_done = t_stats = None
    snap_a = snap_b = None
    sampler = None
    while True:
        chunk = os.read(fd, 65536)
        now = time.monotonic()
        if not chunk:
            break
        buf += chunk
        if t_done is None and b"Loading database information... done." in buf:
            t_done = now
            snap_a = (time.monotonic(), vmstat(), diskstats(devs))
            perf_cmd("enable")
            target = p.pid
            if ctl:  # perf is the parent; the classifier is its child
                try:
                    with open("/proc/%d/task/%d/children" % (p.pid, p.pid)) as f:
                        target = int(f.read().split()[0])
                except (OSError, IndexError, ValueError):
                    target = None
            if target and os.path.isdir("/proc/%d/task" % target):
                sampler = Sampler(target, a.hz, arch)
                sampler.start()
        if t_stats is None and re.search(rb"sequences \([0-9.]+ Mbp\) processed in", buf):
            t_stats = now
            perf_cmd("disable")
            snap_b = (time.monotonic(), vmstat(), diskstats(devs))
            if sampler:
                sampler.stop.set()
    rc = p.wait()
    t1 = time.monotonic()
    if timer:
        timer.cancel()
    if sampler:
        sampler.stop.set()
        sampler.join(2)
    if snap_a and not snap_b:   # killed or failed mid-classify: window ends at exit
        perf_cmd("disable")
        snap_b = (t1, vmstat(), diskstats(devs))
    for f in (ctl_fd, ack_fd):
        if f is not None:
            os.close(f)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    with open(a.out + ".stderr", "wb") as f:
        f.write(buf)
    rnd = lambda x, n=6: None if x is None else round(x, n)
    m = re.search(rb"processed in ([0-9.]+)s", buf)
    out = {
        "exit": rc, "timed_out": timed_out[0], "threads": a.threads,
        "wall_s": rnd(t1 - t0),
        "load_s": rnd(None if t_done is None else t_done - t0),
        "classify_s": float(m.group(1)) if m else None,
        "tail_s": rnd(None if t_stats is None else t1 - t_stats),
        "minflt": after.ru_minflt - before.ru_minflt,
        "majflt": after.ru_majflt - before.ru_majflt,
        "user_s": rnd(after.ru_utime - before.ru_utime),
        "sys_s": rnd(after.ru_stime - before.ru_stime),
        "nvcsw": after.ru_nvcsw - before.ru_nvcsw,
        "nivcsw": after.ru_nivcsw - before.ru_nivcsw,
        "maxrss": after.ru_maxrss,
    }
    win = None
    if snap_a and snap_b:
        win = snap_b[0] - snap_a[0]
        out["window_s"] = rnd(win)
        if snap_a[1] is not None and snap_b[1] is not None:
            out["vmstat"] = {k: snap_b[1].get(k, 0) - snap_a[1].get(k, 0) for k in snap_b[1]}
        if snap_a[2] is not None and snap_b[2] is not None and win > 0:
            disks = {}
            for d, b in snap_b[2].items():
                x = snap_a[2].get(d)
                if not x:
                    continue
                ios = b["rd_ios"] - x["rd_ios"]
                byt = (b["rd_sectors"] - x["rd_sectors"]) * 512
                disks[d] = {"rd_ios": ios, "rd_bytes": byt,
                            "aqu_sz": rnd((b["time_in_queue"] - x["time_in_queue"]) / (win * 1000.0), 3),
                            "util": rnd((b["io_ticks"] - x["io_ticks"]) / (win * 1000.0), 3),
                            "rd_await_ms": rnd((b["rd_ticks"] - x["rd_ticks"]) / ios, 4) if ios else None,
                            "rd_kib_per_io": rnd(byt / 1024.0 / ios, 2) if ios else None,
                            "rd_mib_s": rnd(byt / 1048576.0 / win, 2), "r_iops": rnd(ios / win, 1)}
            out["disks"] = disks
    if perf_out:
        out["perf"] = parse_perf(perf_out)
    if sampler:
        tot = sum(sampler.thr.values()) or 1
        ktot = sum(sampler.kids.values())
        out["sampler"] = {"samples": sampler.n, "hz": a.hz, "max_tasks": sampler.max_threads,
                          "thread_frac": {k: rnd(v / tot, 4) for k, v in sampler.thr.items()},
                          "child_frac": ({k: rnd(v / ktot, 4) for k, v in sampler.kids.items()}
                                         if ktot else None)}
    # derived signatures
    pf = out.get("perf") or {}
    tc = pf.get("task-clock")  # msec
    if tc is not None and win:
        out["offcpu_frac"] = rnd(1 - (tc / 1000.0) / (a.threads * win), 4)
    if pf.get("cycles") and pf.get("instructions"):
        out["ipc"] = rnd(pf["instructions"] / pf["cycles"], 4)
    if pf.get("dTLB-loads") and pf.get("dTLB-load-misses") is not None:
        out["dtlb_miss_ratio"] = rnd(pf["dTLB-load-misses"] / pf["dTLB-loads"], 5)
    vm = out.get("vmstat") or {}
    rd = sum(d["rd_bytes"] for k, d in (out.get("disks") or {}).items() if not k.startswith("nvme")) \
        if any(not k.startswith("nvme") for k in (out.get("disks") or {})) else \
        sum(d["rd_bytes"] for d in (out.get("disks") or {}).values())
    if vm.get("pgmajfault"):
        out["disk_bytes_per_majfault"] = rnd(rd / vm["pgmajfault"], 1)
    out["disk_rd_bytes"] = rd if out.get("disks") else None
    try:
        for f in (ctl, ack):
            if f:
                os.unlink(f)
        os.rmdir(tmpd)
    except OSError:
        pass
    print(json.dumps(out))


if __name__ == "__main__":
    main()
