#!/usr/bin/env python3
"""One instrumented point of the input-path sweep (docs/inputpath.md; #90).

Usage: run_point.py --dir DIR --fq-bytes N --paired 0|1 [--timeout S] [--hz H] -- SCRIPT

Runs `bash -c SCRIPT` (the point's classifier command line, with its decoders in process
substitutions and /usr/bin/time wrappers writing DIR/*.time) in its own session, stdout to
/dev/null and stderr to DIR/stderr.txt, and prints one JSON object on stdout. Instruments:

  wall_s       exec of bash to its exit (decoders start inside it; the DB load is inside it)
  load_s       exec to the arrival of "Loading database information... done."
  classify_s   the classifier's own "processed in X s" figure (upstream's and ours' stderr)
  pidstat      `pidstat -t -u -r -h -H -C REGEX 1` (-H: epoch seconds) for the whole run -> DIR/pidstat.txt, converted
               to DIR/pidstat.csv, the report's schema (docs/inputpath.md): one row per thread
               per second of the run's process group, t_s,tgid,tid,command,role,cpu_pct then
               proc_comm,comm,usr_pct,sys_pct,wait_pct,core,minflt_s,majflt_s,vsz_kb,rss_kb;
               t_s is seconds since the exec (t_done_s and t_stats_s, the classify window, are in
               the same base); the classifier's threads are command kraken2:<comm> with no role
               (the report infers the reader), rapidgzip and gzip get theirs, the rest other.
               Summarised per group: engine_main (the classifier's main thread), engine_workers
               (its other threads), rapidgzip, gzip (upstream's wrapper's gzip -dc), other
  procs        every process of the run's process group seen by a 2 Hz /proc scan: comm, ppid,
               peak VmHWM (kB) as last read, max threads
  smaps        the classifier's /proc/PID/smaps_rollup after the load, max of Rss, AnonHugePages,
               ShmemPmdMapped, FilePmdMapped (kB): whether the table and heap sat on 2 MiB pages
  time         every DIR/*.time file (GNU time -f 'ak2time wall_s=%e maxrss_kb=%M exit=%x
               user_s=%U sys_s=%S' -o FILE): per wrapped process (k2 = the classifier, rg1/rg2 =
               the decoders of mate 1/2), its exit status (128+N when "terminated by signal N"),
               peak RSS (kB) and CPU seconds
Derived: sequences/s and reads/s over classify_s; FASTQ MB/s (the uncompressed FASTQ bytes the
point reads, --fq-bytes) over classify_s and over wall_s.
--timeout kills the session (TERM, then KILL after 10 s) and sets timed_out (a censored point).
Linux only (pidstat, /proc).
"""
import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

ENGINES = ("classify", "aws-kraken2")
REGEX = "classify|kraken2|rapidgzip|gzip|perl"


def stat_of(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            s = f.read()
    except OSError:
        return None
    i, j = s.find("("), s.rfind(")")
    rest = s[j + 2:].split()
    return {"comm": s[i + 1:j], "ppid": int(rest[1]), "pgrp": int(rest[2])}


def status_kb(pid, keys):
    out = {}
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                k, _, v = line.partition(":")
                if k in keys:
                    out[k] = int(v.split()[0])
    except (OSError, ValueError, IndexError):
        pass
    return out


def smaps(pid):
    out = {}
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                k, _, v = line.partition(":")
                if k in ("Rss", "AnonHugePages", "ShmemPmdMapped", "FilePmdMapped", "Anonymous"):
                    out[k + "_kb"] = int(v.split()[0])
    except (OSError, ValueError, IndexError):
        pass
    return out


def parse_time(path):
    rec = {"file": os.path.basename(path)}
    try:
        txt = open(path).read()
    except OSError:
        return rec | {"missing": True}
    m = re.search(r"terminated by signal (\d+)", txt)
    sig = int(m.group(1)) if m else None
    m2 = re.search(r"exited with non-zero status (\d+)", txt)
    for k, v in re.findall(r"(\w+)=([-0-9.]+)", txt.split("ak2time", 1)[-1] if "ak2time" in txt else ""):
        try:
            rec[k] = float(v) if "." in v else int(v)
        except ValueError:
            rec[k] = v
    rec["signal"] = sig
    if sig is not None:
        rec["exit"] = 128 + sig
    elif m2:
        rec["exit"] = int(m2.group(1))
    if "ak2time" not in txt:
        rec["unparsed"] = txt[-300:]
    return rec


def role_of(proc_comm):
    """The report's pidstat role (docs/inputpath.md, "Records and report"). The classifier's
    threads get none: upstream has no dedicated reader thread (each worker reads its block under
    omp critical(seqread)) and ours' goroutines are not threads, so the report infers the reader
    as the busiest engine thread and says so."""
    if proc_comm in ENGINES:
        return ""
    if proc_comm == "rapidgzip":
        return "rapidgzip"
    if proc_comm == "gzip":
        return "gzip"
    return "other"


def pidstat_convert(txt_path, csv_path, pids, t0):
    """pidstat -t -h text -> the report's CSV (thread rows only, each with its TGID; t_s = seconds
    since the point's exec, the classify_window's time base), and a per-group summary."""
    rows, names, cur_tgid, cur_comm, rss = [], None, None, {}, {}
    try:
        lines = open(txt_path).read().splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("#"):
            names = line[1:].split()
            continue
        if not names or not line.strip() or line.startswith(("Linux", "Average")):
            continue
        t = line.split()
        if len(t) < len(names):
            continue
        r = dict(zip(names, t[:len(names) - 1] + [" ".join(t[len(names) - 1:])]))
        cmd = r.get("Command", "")
        if r.get("TGID", "-") != "-":
            cur_tgid = int(r["TGID"])
            cur_comm[cur_tgid] = cmd
            if not pids or cur_tgid in pids:
                try:
                    rss[cur_tgid] = max(rss.get(cur_tgid, 0), int(r.get("RSS", 0)))
                except ValueError:
                    pass
            continue
        if cur_tgid is None or (pids and cur_tgid not in pids):
            continue
        try:
            ts = round(float(r.get("Time")) - t0, 3)
        except (TypeError, ValueError):
            continue
        pc = cur_comm.get(cur_tgid, "")
        comm = cmd.replace("|__", "")
        rows.append({"t_s": ts, "tgid": cur_tgid, "tid": int(r["TID"]),
                     "command": ("kraken2:" + comm) if pc in ENGINES else comm, "role": role_of(pc),
                     "cpu_pct": r.get("%CPU"), "proc_comm": pc, "comm": comm, "usr_pct": r.get("%usr"),
                     "sys_pct": r.get("%system"), "wait_pct": r.get("%wait"), "core": r.get("CPU"),
                     "minflt_s": r.get("minflt/s"), "majflt_s": r.get("majflt/s"), "vsz_kb": r.get("VSZ"),
                     "rss_kb": r.get("RSS")})
    cols = ["t_s", "tgid", "tid", "command", "role", "cpu_pct", "proc_comm", "comm", "usr_pct", "sys_pct",
            "wait_pct", "core", "minflt_s", "majflt_s", "vsz_kb", "rss_kb"]
    with open(csv_path, "w") as f:
        f.write(",".join(cols) + "\n")
        for r in rows:
            f.write(",".join(str(r[c] if r[c] is not None else "") for c in cols) + "\n")

    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return 0.0

    def group(r):
        pc = r["proc_comm"]
        if pc in ENGINES:
            return "engine_main" if r["tid"] == r["tgid"] else "engine_workers"
        if pc in ("rapidgzip", "gzip"):
            return pc
        if pc in ("kraken2", "perl"):
            return "wrapper"
        return "other"

    groups, per_tid = {}, {}
    for r in rows:
        g = group(r)
        d = groups.setdefault(g, {"cpu_s": 0.0, "usr_s": 0.0, "sys_s": 0.0, "tids": set(), "samples": 0})
        d["cpu_s"] += num(r["cpu_pct"]) / 100
        d["usr_s"] += num(r["usr_pct"]) / 100
        d["sys_s"] += num(r["sys_pct"]) / 100
        d["tids"].add(r["tid"])
        d["samples"] += 1
        per_tid.setdefault((g, r["tid"]), []).append(num(r["cpu_pct"]))
    out = {}
    for g, d in groups.items():
        means = [sum(v) / len(v) for (gg, _), v in per_tid.items() if gg == g]
        peaks = [max(v) for (gg, _), v in per_tid.items() if gg == g]
        out[g] = {"cpu_s": round(d["cpu_s"], 2), "usr_s": round(d["usr_s"], 2), "sys_s": round(d["sys_s"], 2),
                  "threads": len(d["tids"]), "samples": d["samples"],
                  "max_thread_mean_cpu_pct": round(max(means), 1) if means else None,
                  "max_thread_peak_cpu_pct": round(max(peaks), 1) if peaks else None}
    return {"groups": out, "proc_rss_kb_max": {str(k): {"comm": cur_comm.get(k, ""), "rss_kb": v} for k, v in rss.items()},
            "rows": len(rows), "seconds": len({r["t_s"] for r in rows})}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--fq-bytes", type=int, required=True)
    ap.add_argument("--paired", type=int, choices=(0, 1), required=True)
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--hz", type=float, default=2)
    ap.add_argument("script", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    script = a.script[1:] if a.script[:1] == ["--"] else a.script
    if len(script) != 1:
        ap.error("want exactly one SCRIPT after --")
    os.makedirs(a.dir, exist_ok=True)
    env = dict(os.environ, LC_ALL="C")
    pst = None
    try:
        pst = subprocess.Popen(["pidstat", "-t", "-u", "-r", "-h", "-H", "-C", REGEX, "1"], stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(a.dir, "pidstat.txt"), "w"), stderr=subprocess.DEVNULL,
                               env=env, start_new_session=True)
    except OSError:
        pst = None
    marks = {}
    t0 = time.time()
    p = subprocess.Popen(["bash", "-c", script[0]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, start_new_session=True)
    errf = open(os.path.join(a.dir, "stderr.txt"), "wb")
    buf = bytearray()

    def reader():
        while True:
            b = p.stderr.read1(65536) if hasattr(p.stderr, "read1") else p.stderr.read(65536)
            if not b:
                break
            errf.write(b)
            buf.extend(b)
            now = time.time()
            if "done" not in marks and b"Loading database information... done." in buf:
                marks["done"] = now
            if "stats" not in marks and re.search(rb"sequences \([0-9.]+ Mbp\) processed in", buf):
                marks["stats"] = now

    seen, eng_smaps, stop = {}, {}, threading.Event()

    def scan():
        pg = p.pid
        alive = 0
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            s = stat_of(d)
            if not s or s["pgrp"] != pg:
                continue
            alive += 1
            pid = int(d)
            e = seen.setdefault(pid, {"comm": s["comm"], "ppid": s["ppid"], "first_s": round(time.time() - t0, 2),
                                      "hwm_kb": 0, "threads_max": 0})
            e["comm"] = s["comm"]
            st = status_kb(pid, ("VmHWM", "Threads"))
            e["hwm_kb"] = max(e["hwm_kb"], st.get("VmHWM", 0))
            e["threads_max"] = max(e["threads_max"], st.get("Threads", 0))
            e["last_s"] = round(time.time() - t0, 2)
            if s["comm"] in ENGINES and "done" in marks:
                for k, v in smaps(pid).items():
                    eng_smaps[k] = max(eng_smaps.get(k, 0), v)
        return alive

    def sampler():
        while not stop.is_set():
            scan()
            stop.wait(1 / a.hz)

    rt = threading.Thread(target=reader, daemon=True)
    st = threading.Thread(target=sampler, daemon=True)
    rt.start()
    st.start()
    timed_out = False
    try:
        rc = p.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        for sig, w in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                pass
            try:
                rc = p.wait(timeout=w)
                break
            except subprocess.TimeoutExpired:
                rc = None
    t1 = time.time()
    rt.join(5)
    # The decoders may outlive the classifier by a moment (and write their .time files then):
    # wait until the session's process group is empty (at most 15 s), then stop the sampler.
    for _ in range(150):
        if scan() == 0:
            break
        time.sleep(0.1)
    leftover = scan()
    stop.set()
    st.join(2)
    errf.close()
    if pst:
        try:
            os.killpg(pst.pid, signal.SIGINT)
            pst.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(pst.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    pids = set(seen)
    ps = pidstat_convert(os.path.join(a.dir, "pidstat.txt"), os.path.join(a.dir, "pidstat.csv"), pids, t0) if pst else None
    m = re.search(rb"(\d+) sequences \(([0-9.]+) Mbp\) processed in ([0-9.]+)s", buf)
    mc = re.search(rb"(\d+) sequences classified", buf)
    seqs = int(m.group(1)) if m else None
    cls_s = float(m.group(3)) if m else None
    times = {os.path.basename(f)[:-5]: parse_time(f) for f in sorted(glob.glob(os.path.join(a.dir, "*.time")))}
    wall = t1 - t0
    rd = lambda x, n=3: None if x is None else round(x, n)
    out = {
        "exit": rc, "timed_out": timed_out, "wall_s": rd(wall),
        "load_s": rd(marks["done"] - t0) if "done" in marks else None,
        "classify_s": cls_s,
        "tail_s": rd(t1 - marks["stats"]) if "stats" in marks else None,
        "t_done_s": rd(marks["done"] - t0) if "done" in marks else None,
        "t_stats_s": rd(marks["stats"] - t0) if "stats" in marks else None,
        "sequences": seqs, "mbp": float(m.group(2)) if m else None,
        "classified": int(mc.group(1)) if mc else None,
        "seq_per_s": rd(seqs / cls_s, 1) if seqs and cls_s else None,
        "reads_per_s": rd(seqs * (2 if a.paired else 1) / cls_s, 1) if seqs and cls_s else None,
        "fq_bytes": a.fq_bytes,
        "fq_mb_per_s_classify": rd(a.fq_bytes / cls_s / 1e6, 1) if cls_s else None,
        "fq_mb_per_s_wall": rd(a.fq_bytes / wall / 1e6, 1) if wall > 0 else None,
        "time": times,
        "procs": {str(k): v for k, v in seen.items()},
        "procs_left_after_15s": leftover,
        "smaps_max": eng_smaps or None,
        "pidstat": ps,
        "pidstat_csv": os.path.join(a.dir, "pidstat.csv") if ps is not None else None,
    }
    if rc != 0 or timed_out or seqs is None:
        out["stderr_tail"] = bytes(buf[-600:]).decode("utf-8", "replace")
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
