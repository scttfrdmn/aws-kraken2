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
CAP = {"vcpus": 4, "memory_mib": 8192, "baseline_gbps": 10.0, "peak_gbps": 25.0}


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


def write_run(root, name, launch, term, btime, ticks, cap=True, extra_lines=()):
    """ticks: (t, phase, tag, busy_ticks, used_kib, rx, tx, k). busy is split across user, system,
    softirq and steal; iowait is non-zero and must not count."""
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "log"))
    man = {"run_id": name, "region": "us-west-2", "billed_seconds": term - launch, "cost_usd": 0.4,
           "instance": {"type": "x.test", "launch_time": iso(launch), "terminated_at": iso(term)}}
    if cap:
        man["instance"]["type_info"] = CAP
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(man, f)
    if ticks is None:
        return d
    lines = ["H\tformat\tak2-util-1", f"H\tbtime\t{btime}", "H\tclk_tck\t100", "H\tncpu\t4", "H\tiface\teth0", "H\tevery\t1"]
    lines += list(extra_lines)
    for t, phase, tag, b, used, rx, tx, k in ticks:
        user, system, sirq, steal = b // 2, b // 4, b // 8, b - b // 2 - b // 4 - b // 8
        lines.append("\t".join(map(str, ["S", f"{t}.000", phase, tag, user, 0, system, 9999, 77, 0, sirq, steal, user // 3, 0,
                                          8 * GIB_KIB, 8 * GIB_KIB - used, 0, rx, tx, 100 * k, k,
                                          1_000_000 * k, 600_000 * k, 400_000 * k])))
    with open(os.path.join(d, "log", "util.tsv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return d


def std_ticks(reset_tx=False):
    """Ticks 1020..1030 (1 Hz). Busy: 400 ticks at the first (4 s since boot), +200 per s (2 vCPUs).
    Used memory 1 GiB, 3 GiB at tick 7. rx: 250e6 bytes before the first tick (since boot), then
    +100e6 B/s; tx +25e6 B/s. Phases: ticks 0-4 "a", 5-9 "b", 10 "end" (final)."""
    out = []
    for k in range(11):
        tx = 25_000_000 * k
        if reset_tx and k >= 7:
            tx = 1000 * k       # the counter restarts between ticks 6 and 7
        out.append((1020 + k, "a" if k < 5 else ("end" if k == 10 else "b"), "final" if k == 10 else "tick",
                    400 + 200 * k, 3 * GIB_KIB if k == 7 else GIB_KIB, 250_000_000 + 100_000_000 * k, tx, k))
    return out


def read(path):
    with open(path) as f:
        return list(csv.DictReader(f, delimiter="\t"))


def by(rows, scope, key="phase"):
    return {r[key]: r for r in rows if r["scope"] == scope}


with tempfile.TemporaryDirectory() as T:
    g = os.path.join(T, "results", "g9")
    ext = ["E\t1020.000\tstart\tbw_in_allowance_exceeded\t5", "E\t1020.000\tstart\tpps_allowance_exceeded\t0",
           "S\t1024.5\tb\ttick\t1", "E\t1030.000\tend\tbw_in_allowance_exceeded\t12", "E\t1030.000\tend\tpps_allowance_exceeded\t0"]
    d = write_run(g, "run-a", 1000, 1040, 1010, std_ticks(), extra_lines=ext)
    assert util.main([d]) == 0
    rows = read(os.path.join(d, "tables", "util.tsv"))
    node = by(rows, "node", "scope")["node"]
    check("node seconds = billed", node["seconds"], 40)
    check("busy vCPU-s from /proc/stat since boot (2400 ticks / 100)", node["busy_vcpu_s"], 24)
    check("U_cpu = 24 / (4 x 40)", node["U_cpu"], 0.15)
    check("U_mem mean = (10 GiB-s + 2 GiB-s trapezoid) / 40 s / 8 GiB", node["U_mem_mean"], 0.0375)
    check("U_mem peak = 3 / 8", node["U_mem_peak"], 0.375)
    check("mem_gap_s = 0 (no gaps)", node["mem_gap_s"], 0)
    check("rx from boot = 250e6 + 10 x 100e6", node["rx_bytes"], 1.25e9)
    check("tx from boot = 10 x 25e6", node["tx_bytes"], 2.5e8)
    check("net bytes = rx + tx", node["net_bytes"], 1.5e9)
    check("U_net baseline = 1.5e9 / (1.25e9 B/s x 40 s)", node["U_net_baseline"], 0.03)
    check("U_net peak = 1.5e9 / (3.125e9 B/s x 40 s)", node["U_net_peak"], 0.012)
    check("U_net_rx baseline = 1.25e9 / 50e9", node["U_net_rx_baseline"], 0.025)
    check("U_net_tx baseline = 2.5e8 / 50e9", node["U_net_tx_baseline"], 0.005)
    check("U_net_tx peak = 2.5e8 / 125e9", node["U_net_tx_peak"], 0.002)
    check("eff cost cpu = 0.4 / 0.15", node["eff_cost_cpu_usd"], 0.4 / 0.15, 1e-6)
    check("x_cpu = 1 / 0.15", node["x_cpu"], 6.67, 0.005)
    check("eff cost net at baseline = 0.4 / 0.03", node["eff_cost_net_baseline_usd"], 0.4 / 0.03, 1e-6)
    check("unobservable launch -> btime", node["unobs_launch_to_boot_s"], 10)
    check("btime -> first tick", node["unobs_boot_to_sampler_s"], 10)
    check("unobservable last tick -> terminated", node["unobs_last_to_term_s"], 10)
    check("task cgroup CPU (10 s of 1e6 usec)", node["task_cgroup_cpu_s"], 10)
    check("task cgroup sys", node["task_cgroup_sys_s"], 4)
    check("pgfault delta", node["pgfault"], 1000)
    check("allowance deltas", node["allowance_exceeded"], "bw_in_allowance_exceeded=7;pps_allowance_exceeded=0")
    check("ticks (the cut-off line skipped)", node["ticks"], 11)
    check("coverage notes the skipped line", node["coverage"], "1 malformed line(s) skipped")
    ph = by(rows, "node-phase")
    check("phase a seconds (intervals 0->5)", ph["a"]["seconds"], 5)
    check("phase a busy = 5 s x 2 vCPUs", ph["a"]["busy_vcpu_s"], 10)
    check("phase a U_cpu = 10 / (4 x 5)", ph["a"]["U_cpu"], 0.5)
    check("phase b seconds (5->10)", ph["b"]["seconds"], 5)
    check("phase b peak memory GiB", ph["b"]["mem_used_peak_gib"], 3)
    check("phase b mean memory GiB = (5 + 2) / 5", ph["b"]["mem_used_mean_gib"], 1.4)
    check("boot window carries boot CPU", ph["(boot->first tick)"]["busy_vcpu_s"], 4)
    check("boot window carries boot network (counters since boot)", ph["(boot->first tick)"]["rx_bytes"], 2.5e8)
    check("boot window memory counts 0", ph["(boot->first tick)"]["mem_used_mean_gib"], 0)
    check("launch window CPU counts 0", ph["(launch->boot)"]["busy_vcpu_s"], 0)
    check("post window seconds", ph["(last tick->terminated)"]["seconds"], 10)
    check("post window network counts 0", ph["(last tick->terminated)"]["net_bytes"], 0)
    for col, want in (("seconds", 40), ("busy_vcpu_s", 24), ("net_bytes", 1.5e9)):
        check(f"node-phase {col} sum to the node's", sum(float(r[col]) for r in ph.values()), want)
    side = json.load(open(os.path.join(d, "tables", "util.json")))
    truth("util.json records the generator and each input's sha256",
          side["generator"] == "scripts/lib/util.py" and "commit" in side
          and any(x["path"].endswith("run-a/log/util.tsv") and len(x.get("sha256", "")) == 64 for x in side["inputs"]), side["inputs"][:2])

    # A cohort of two: r1 has no sampler record (missing, counted as 0, named by run_id).
    c = os.path.join(g, "coh-n2")
    os.makedirs(c)
    write_run(g, "coh-n2-r0", 1000, 1040, 1010, std_ticks())
    write_run(g, "coh-n2-r1", 1000, 1040, 1010, None)
    with open(os.path.join(c, "cohort.json"), "w") as f:
        json.dump({"cohort_id": "coh-n2", "members": [{"rank": 0, "run_id": "coh-n2-r0"}, {"rank": 1, "run_id": "coh-n2-r1"}]}, f)
    assert util.main([c]) == 0
    rows = read(os.path.join(c, "tables", "util.tsv"))
    fl = by(rows, "fleet", "scope")["fleet"]
    check("fleet node-seconds", fl["seconds"], 80)
    check("fleet U_cpu = 24 / (4 x 80)", fl["U_cpu"], 0.075)
    check("fleet U_mem mean = 12 GiB-s / (8 GiB x 80 s)", fl["U_mem_mean"], 0.01875)
    check("fleet U_net baseline = 1.5e9 / (1.25e9 B/s x 80 s)", fl["U_net_baseline"], 0.015)
    check("fleet cost", fl["cost_usd"], 0.8)
    check("fleet eff cost cpu = 0.8 / 0.075", fl["eff_cost_cpu_usd"], 0.8 / 0.075, 1e-5)
    truth("fleet coverage names the missing node by run_id", "CPU missing on 1 of 2 node(s) (coh-n2-r1)" in fl["coverage"], fl["coverage"])
    truth("fleet coverage carries the node notes", "node notes: coh-n2-r1: no log/util.tsv" in fl["coverage"], fl["coverage"])
    n1 = by(rows, "node", "node")["coh-n2-r1"]
    check("node without util.tsv: U_cpu empty", n1["U_cpu"], "")
    truth("node without util.tsv: coverage says why", n1["coverage"].startswith("no log/util.tsv"), n1["coverage"])

    # #58: the fleet row sums each allowance counter over its nodes. r0: bw_in 5 -> 12 (7), pps 0.
    # r1: bw_in 100 -> 110 (10), pps 1 -> 4 (3), linklocal 0 -> 2 (2; r0 lacks it), conntrack
    # start only (no delta). r2: no E lines. Fleet: bw_in 17, linklocal 2, pps 3; r2 named as
    # lacking the counters, r0 as lacking linklocal.
    c = os.path.join(g, "coh-al")
    os.makedirs(c)
    e1 = ["E\t1020.000\tstart\tbw_in_allowance_exceeded\t100", "E\t1020.000\tstart\tpps_allowance_exceeded\t1",
          "E\t1020.000\tstart\tlinklocal_allowance_exceeded\t0", "E\t1020.000\tstart\tconntrack_allowance_exceeded\t0",
          "E\t1030.000\tend\tbw_in_allowance_exceeded\t110", "E\t1030.000\tend\tpps_allowance_exceeded\t4",
          "E\t1030.000\tend\tlinklocal_allowance_exceeded\t2"]
    write_run(g, "coh-al-r0", 1000, 1040, 1010, std_ticks(), extra_lines=ext)
    write_run(g, "coh-al-r1", 1000, 1040, 1010, std_ticks(), extra_lines=e1)
    write_run(g, "coh-al-r2", 1000, 1040, 1010, std_ticks())
    with open(os.path.join(c, "cohort.json"), "w") as f:
        json.dump({"cohort_id": "coh-al", "members": [{"rank": i, "run_id": f"coh-al-r{i}"} for i in range(3)]}, f)
    assert util.main([c]) == 0
    rows = read(os.path.join(c, "tables", "util.tsv"))
    fl = by(rows, "fleet", "scope")["fleet"]
    check("#58: fleet allowance = per-counter sums over the nodes", fl["allowance_exceeded"],
          "bw_in_allowance_exceeded=17;linklocal_allowance_exceeded=2;pps_allowance_exceeded=3")
    truth("#58: fleet coverage names the node without the counters",
          "allowance counters missing on 1 of 3 node(s) (coh-al-r2): summed over the rest" in fl["coverage"], fl["coverage"])
    truth("#58: fleet coverage names the node without one counter",
          "allowance counter linklocal_allowance_exceeded missing on 1 of 3 node(s) (coh-al-r0)" in fl["coverage"], fl["coverage"])
    truth("#58: fleet coverage names a start-only counter as unpaired, not missing",
          "allowance counter conntrack_allowance_exceeded unpaired (start or end only) on 1 of 3 node(s) (coh-al-r1)"
          in fl["coverage"] and "conntrack_allowance_exceeded missing on 1 of 3 node(s) (coh-al-r0)" in fl["coverage"]
          and "(coh-al-r1)" not in fl["coverage"].split("conntrack_allowance_exceeded missing")[1].split(";")[0], fl["coverage"])
    nd = by(rows, "node", "node")
    check("#58: node r1 row unchanged (unpaired counter shown raw)", nd["coh-al-r1"]["allowance_exceeded"],
          "bw_in_allowance_exceeded=10;conntrack_allowance_exceeded=start:0,end:-;linklocal_allowance_exceeded=2;"
          "pps_allowance_exceeded=3")
    check("#58: node r2 row says not recorded", nd["coh-al-r2"]["allowance_exceeded"], "not recorded")
    # A single run: the fleet row carries the node's counters.
    fl1 = by(read(os.path.join(g, "run-a", "tables", "util.tsv")), "fleet", "scope")["fleet"]
    check("#58: one-node fleet allowance = the node's", fl1["allowance_exceeded"],
          "bw_in_allowance_exceeded=7;pps_allowance_exceeded=0")

    # B1: a node without capacity must leave the numerators too. With it counted only in the
    # numerators the fleet's U_cpu was 48 / (4 x 40) = 0.30 here (1.5 with 4x the work).
    c = os.path.join(g, "coh-b1")
    os.makedirs(c)
    write_run(g, "coh-b1-r0", 1000, 1040, 1010, std_ticks())
    write_run(g, "coh-b1-r1", 1000, 1040, 1010, std_ticks(), cap=False)
    with open(os.path.join(c, "cohort.json"), "w") as f:
        json.dump({"cohort_id": "coh-b1", "members": [{"rank": 0, "run_id": "coh-b1-r0"}, {"rank": 1, "run_id": "coh-b1-r1"}]}, f)
    util.main([c])
    rows = read(os.path.join(c, "tables", "util.tsv"))
    fl = by(rows, "fleet", "scope")["fleet"]
    check("B1: fleet U_cpu over the capacity nodes only = 24 / (4 x 40)", fl["U_cpu"], 0.15)
    check("B1: fleet busy vCPU-s excludes the capacity-less node", fl["busy_vcpu_s"], 24)
    check("B1: fleet seconds = the included node's", fl["seconds"], 40)
    check("B1: fleet U_net baseline = 1.5e9 / 50e9", fl["U_net_baseline"], 0.03)
    truth("B1: the excluded node is named", "excluded (no capacity or billed window): 1 of 2 node(s) (coh-b1-r1)" in fl["coverage"], fl["coverage"])
    fp = by(rows, "fleet-phase")
    check("B1: fleet-phase a U_cpu = 0.5 (one node)", fp["a"]["U_cpu"], 0.5)

    # B2: a 990 s gap must not be interpolated. Billed 1000 s; used memory 8 GiB (all of it) at
    # every tick; ticks at 1..5 and 995..1000 (1 Hz). Observed memory-s = (4 + 5) x 8 GiB, so
    # U_mem = 9 / 1000; interpolating the gap gave 0.999 with coverage "full".
    tk = [(t, "w", "final" if t == 1000 else "tick", 100 * t, 8 * GIB_KIB, 0, 0, t) for t in list(range(1, 6)) + list(range(995, 1001))]
    d = write_run(g, "run-gap", 0, 1000, 0, tk)
    util.main([d])
    rows = read(os.path.join(d, "tables", "util.tsv"))
    node = by(rows, "node", "scope")["node"]
    check("B2: U_mem mean counts the gap as 0", node["U_mem_mean"], 0.009)
    check("B2: mem_gap_s", node["mem_gap_s"], 990)
    check("B2: U_mem peak still sees the samples", node["U_mem_peak"], 1.0)
    truth("B2: coverage names the gap", "memory: 1 gap(s) > 2.5 s totalling 990.0 s counted as 0" in node["coverage"], node["coverage"])
    check("B2: CPU is a counter, integrated across the gap (1000 s x 1 vCPU)", node["busy_vcpu_s"], 1000)

    # A counter that goes backwards: None plus a note, never a silent 0.
    d = write_run(g, "run-reset", 1000, 1040, 1010, std_ticks(reset_tx=True))
    util.main([d])
    rows = read(os.path.join(d, "tables", "util.tsv"))
    node = by(rows, "node", "scope")["node"]
    check("reset: node tx empty", node["tx_bytes"], "")
    check("reset: node U_net empty", node["U_net_baseline"], "")
    check("reset: node rx still counted", node["rx_bytes"], 1.25e9)
    truth("reset: coverage says so", "tx counter went backwards" in node["coverage"], node["coverage"])
    ph = by(rows, "node-phase")
    check("reset: phase b tx empty", ph["b"]["tx_bytes"], "")
    truth("reset: phase b coverage says so", "tx counter went backwards" in ph["b"]["coverage"], ph["b"]["coverage"])
    check("reset: phase a tx intact (5 x 25e6)", ph["a"]["tx_bytes"], 1.25e8)

    # Late interface (the reviewer's probe): no counters at ticks 0-2, 5e9 rx since boot at tick 3,
    # then +100e6 rx and +25e6 tx per s to tick 10. Everything since btime must be counted:
    # rx = 5e9 + 7 x 100e6, tx = 2e9 (since boot at tick 3) + 7 x 25e6.
    tk = []
    for t0, ph_, tag, b, used, rx, tx, k in std_ticks():
        if k < 3:
            rx = tx = ""
        else:
            rx, tx = 5_000_000_000 + 100_000_000 * (k - 3), 2_000_000_000 + 25_000_000 * (k - 3)
        tk.append((t0, ph_, tag, b, used, rx, tx, k))
    d = write_run(g, "run-lateif", 1000, 1040, 1010, tk)
    util.main([d])
    rows = read(os.path.join(d, "tables", "util.tsv"))
    node = by(rows, "node", "scope")["node"]
    check("late iface: rx = 5e9 since boot + 7 x 100e6", node["rx_bytes"], 5.7e9)
    check("late iface: tx = 2e9 since boot + 7 x 25e6", node["tx_bytes"], 2.175e9)
    ph = by(rows, "node-phase")
    check("late iface: boot window carries the since-boot value", ph["(boot->first tick)"]["rx_bytes"], 5e9)
    truth("late iface: coverage says where it went", "rx counter first read at t=1023" in node["coverage"], node["coverage"])

    # Largest tick gap per phase: phase a has a 3 s interval (ticks 1020, 1021, 1024, 1025).
    tk = [(t, "a" if t < 1025 else "b", "final" if t == 1027 else "tick", 100 * t, GIB_KIB, t, t, t)
          for t in (1020, 1021, 1024, 1025, 1026, 1027)]
    d = write_run(g, "run-gaps", 1000, 1040, 1010, tk)
    util.main([d])
    ph = by(read(os.path.join(d, "tables", "util.tsv")), "node-phase")
    check("max gap in phase a", ph["a"]["max_gap_s"], 3)
    check("max gap in phase b", ph["b"]["max_gap_s"], 1)
    check("phase a mem_gap_s (the 3 s interval exceeds 2.5 s)", ph["a"]["mem_gap_s"], 3)

    # No capacity: utilisations empty, named.
    d = write_run(g, "run-nocap", 1000, 1040, 1010, std_ticks(), cap=False)
    util.main([d])
    node = by(read(os.path.join(d, "tables", "util.tsv")), "node", "scope")["node"]
    check("no capacity: U_cpu empty", node["U_cpu"], "")
    truth("no capacity: coverage", "no capacity" in node["coverage"], node["coverage"])

print("util_test:", "FAILED " + ", ".join(FAIL) if FAIL else "all ok")
sys.exit(1 if FAIL else 0)
