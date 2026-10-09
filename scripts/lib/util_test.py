#!/usr/bin/env python3
"""make test: scripts/lib/util.py on synthetic counter files (synthetic data is for unit tests
only; CLAUDE.md Law 3). Every expected value below is worked by hand from the counters."""
import csv
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import util  # noqa: E402

GIB_KIB = 1048576
FAIL = []


def check(what, got, want, tol=1e-9):
    ok = (got == want) if isinstance(want, str) else (got not in ("", None) and abs(float(got) - want) <= tol)
    print(f"util_test: {'ok  ' if ok else 'FAIL'} {what}: got {got!r}, want {want!r}")
    if not ok:
        FAIL.append(what)


def truth(what, cond, got):
    print(f"util_test: {'ok  ' if cond else 'FAIL'} {what}: {got!r}")
    if not cond:
        FAIL.append(what)


def iso(t):
    import datetime as dt
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat()


def node_dir(root, name, with_util=True, cap=True):
    """launch 1000, btime 1010, ticks 1020..1030 (1 Hz), terminated 1040: billed 40 s.
    4 vCPUs, USER_HZ 100. Busy ticks: 400 at the first tick (4 s from boot), +200 per s (2 vCPUs).
    Memory: MemTotal 8 GiB, used 1 GiB, 3 GiB at tick 7. Network: +125e6 B/s (1 Gbit/s).
    Phases: ticks 0-4 "a", 5-10 "b" (the last tagged final, phase "end" on the last tick)."""
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "log"))
    man = {"region": "us-west-2", "billed_seconds": 40, "cost_usd": 0.4,
           "instance": {"type": "x.test", "launch_time": iso(1000), "terminated_at": iso(1040)}}
    if cap:
        man["instance"]["type_info"] = {"vcpus": 4, "memory_mib": 8192, "baseline_gbps": 10.0, "peak_gbps": 25.0}
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(man, f)
    if not with_util:
        return d
    lines = ["H\tformat\tak2-util-1", "H\tbtime\t1010", "H\tclk_tck\t100", "H\tncpu\t4", "H\tiface\teth0",
             "E\t1020.000\tstart\tbw_in_allowance_exceeded\t5", "E\t1020.000\tstart\tpps_allowance_exceeded\t0"]
    for k in range(11):
        b = 400 + 200 * k
        # user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice: busy split
        # across user (half), system (a quarter), softirq and steal (an eighth each); iowait is idle.
        user, system, sirq, steal = b // 2, b // 4, b // 8, b - b // 2 - b // 4 - b // 8
        used = 3 * GIB_KIB if k == 7 else GIB_KIB
        rx, tx = 1000 + 100_000_000 * k, 2000 + 25_000_000 * k
        phase = "a" if k < 5 else ("end" if k == 10 else "b")
        tag = "final" if k == 10 else "tick"
        lines.append("\t".join(map(str, ["S", f"{1020 + k}.000", phase, tag, user, 0, system, 9999, 77, 0, sirq, steal,
                                          user // 3, 0, 8 * GIB_KIB, 8 * GIB_KIB - used, 0, rx, tx, 100 * k, k,
                                          1_000_000 * k, 600_000 * k, 400_000 * k])))
        if k == 4:
            lines.append("S\t1024.5\tb\ttick\t1")   # a tick cut off by a kill: skipped
    lines += ["E\t1030.000\tend\tbw_in_allowance_exceeded\t12", "E\t1030.000\tend\tpps_allowance_exceeded\t0"]
    with open(os.path.join(d, "log", "util.tsv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return d


def read(path):
    with open(path) as f:
        return list(csv.DictReader(f, delimiter="\t"))


with tempfile.TemporaryDirectory() as T:
    g = os.path.join(T, "results", "g9")
    d = node_dir(g, "run-a")
    assert util.main([d]) == 0
    rows = read(os.path.join(d, "tables", "util.tsv"))
    node = [r for r in rows if r["scope"] == "node"][0]
    check("node seconds = billed", node["seconds"], 40)
    check("busy vCPU-s from /proc/stat since boot (2400 ticks / 100)", node["busy_vcpu_s"], 24)
    check("U_cpu = 24 / (4 x 40)", node["U_cpu"], 0.15)
    check("U_mem mean = (10 GiB-s + 2 GiB-s trapezoid) / 40 s / 8 GiB", node["U_mem_mean"], 0.0375)
    check("U_mem peak = 3 / 8", node["U_mem_peak"], 0.375)
    check("net bytes = 10 x 125e6", node["net_bytes"], 1.25e9)
    check("U_net baseline = 1.25e9 / (10 Gbit/s x 40 s)", node["U_net_baseline"], 0.025)
    check("U_net peak = 1.25e9 / (25 Gbit/s x 40 s)", node["U_net_peak"], 0.01)
    check("eff cost cpu = 0.4 / 0.15", node["eff_cost_cpu_usd"], 0.4 / 0.15, 1e-6)
    check("x_cpu = 1 / 0.15", node["x_cpu"], 6.67, 0.005)
    check("eff cost net at baseline = 0.4 / 0.025", node["eff_cost_net_baseline_usd"], 16.0)
    check("unobservable launch -> btime", node["unobs_launch_to_boot_s"], 10)
    check("unobservable btime -> first tick", node["unobs_boot_to_sampler_s"], 10)
    check("unobservable last tick -> terminated", node["unobs_last_to_term_s"], 10)
    check("task cgroup CPU (10 s of 1e6 usec)", node["task_cgroup_cpu_s"], 10)
    check("task cgroup sys", node["task_cgroup_sys_s"], 4)
    check("pgfault delta", node["pgfault"], 1000)
    check("allowance deltas", node["allowance_exceeded"], "bw_in_allowance_exceeded=7;pps_allowance_exceeded=0")
    check("ticks (the cut-off line skipped)", node["ticks"], 11)
    check("coverage notes the skipped line", node["coverage"], "1 malformed line(s) skipped")
    ph = {r["phase"]: r for r in rows if r["scope"] == "node-phase"}
    check("phase a seconds (intervals 0->5)", ph["a"]["seconds"], 5)
    check("phase a busy = 5 s x 2 vCPUs", ph["a"]["busy_vcpu_s"], 10)
    check("phase a U_cpu = 10 / (4 x 5)", ph["a"]["U_cpu"], 0.5)
    check("phase b seconds (5->10)", ph["b"]["seconds"], 5)
    check("phase b peak memory GiB", ph["b"]["mem_used_peak_gib"], 3)
    check("phase b mean memory GiB = (5 + 2) / 5", ph["b"]["mem_used_mean_gib"], 1.4)
    check("boot window carries boot CPU", ph["(boot->first tick)"]["busy_vcpu_s"], 4)
    check("boot window memory counts 0", ph["(boot->first tick)"]["mem_used_mean_gib"], 0)
    check("post window seconds", ph["(last tick->terminated)"]["seconds"], 10)
    secs = sum(float(r["seconds"]) for r in rows if r["scope"] == "node-phase")
    check("node-phase seconds sum to billed", secs, 40)
    bsum = sum(float(r["busy_vcpu_s"]) for r in rows if r["scope"] == "node-phase")
    check("node-phase busy sums to the node's", bsum, 24)

    # A cohort of two: rank 1 has no sampler record (missing, counted as 0, named).
    c = os.path.join(g, "coh-n2")
    os.makedirs(c)
    node_dir(g, "coh-n2-r0")
    node_dir(g, "coh-n2-r1", with_util=False)
    with open(os.path.join(c, "cohort.json"), "w") as f:
        json.dump({"cohort_id": "coh-n2", "members": [{"rank": 0, "run_id": "coh-n2-r0"}, {"rank": 1, "run_id": "coh-n2-r1"}]}, f)
    assert util.main([c]) == 0
    rows = read(os.path.join(c, "tables", "util.tsv"))
    fl = [r for r in rows if r["scope"] == "fleet"][0]
    check("fleet node-seconds", fl["seconds"], 80)
    check("fleet U_cpu = 24 / (4 x 80)", fl["U_cpu"], 0.075)
    check("fleet U_mem mean = 12 GiB-s / (8 GiB x 80 s)", fl["U_mem_mean"], 0.01875)
    check("fleet U_net baseline = 1.25e9 / (10 Gbit/s x 80 s)", fl["U_net_baseline"], 0.0125)
    check("fleet cost", fl["cost_usd"], 0.8)
    check("fleet eff cost cpu = 0.8 / 0.075", fl["eff_cost_cpu_usd"], 0.8 / 0.075, 1e-5)
    truth("fleet coverage names the missing node", "CPU missing on 1 of 2 node(s) (r1)" in fl["coverage"], fl["coverage"])
    n1 = [r for r in rows if r["scope"] == "node" and r["node"] == "r1"][0]
    check("node without util.tsv: U_cpu empty", n1["U_cpu"], "")
    truth("node without util.tsv: coverage says why", n1["coverage"].startswith("no log/util.tsv"), n1["coverage"])

    # No capacity: utilisations empty, named.
    d = node_dir(g, "run-nocap", cap=False)
    util.main([d])
    node = [r for r in read(os.path.join(d, "tables", "util.tsv")) if r["scope"] == "node"][0]
    check("no capacity: U_cpu empty", node["U_cpu"], "")
    truth("no capacity: coverage", "no capacity" in node["coverage"], node["coverage"])

print("util_test:", "FAILED " + ", ".join(FAIL) if FAIL else "all ok")
sys.exit(1 if FAIL else 0)
