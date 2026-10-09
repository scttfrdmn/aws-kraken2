#!/usr/bin/env python3
"""make util-backfill (docs/util.md): lower-bound utilisation for the results/g2 and results/g3
runs that predate the sampler (scripts/util-sampler.sh), from what their own files recorded. $0:
reads results/ only. Nothing is imputed: a resource with no record is `missing`, and every U is a
lower bound, because only part of the billed window and only some processes were recorded.

Rows cannot be compared across arms or run types: their CPU sources differ (the engine's whole
process vs upstream's per-run getrusage vs nothing), so a higher lower bound is not higher use.
The `arm` and `cpu_coverage` columns say which source a row has.

Per node run (results/<gate>/<run-id>/manifest.json) and per cohort (cohort.json, summed over
the members with capacity and a billed window; any other member is excluded and named):
  CPU   ours: the engine's getrusage over its whole process, user_s + sys_s of the
              `ak2-timing total` lines (AK2_TIMINGS=1) in log/run.log, else out/**/eng-*.stderr.
        upstream: user_s + sys_s of every `kind: run` row with getrusage in the G2 runner's
              runs.jsonl (G2, U2).
        loadbench (G2 #36): user_s + sys_s of every row of runs.tsv, both arms (impl upstream
              is upstream; every other impl is ours).
  mem   ours: `ak2-engine mem` samples (every 15 s while an engine runs): the time integral of
              rss_kib between the first and last sample of each invocation (U_mem_mean_lb); the
              peak is the largest hwm_kib (U_mem_peak_lb: the engine's table is anonymous heap,
              so its RSS is used memory).
        upstream / loadbench: only a per-process peak RSS (getrusage maxrss), reported as
              rss_peak_gib and never as U_mem: under mmap that RSS is file-backed page cache,
              which the kernel can reclaim, so it is not "used" in U_mem's sense.
  net   bytes the logs state moved: the engine's shard-load bytes (`ak2-engine load ... bytes`)
        and multipart part_bytes (`ak2-engine s3 ... part_bytes`); ak2_stage (`staged s3://...
        (N bytes)`) and the scripted stagers (`staged <name> bytes=N in <s> s`); the campaign's
        `inputs staged and verified: N files, X GB` (less half its last digit); stage-cohort's
        `<file> staged (N bytes`, counted once (its upload of the same bytes is not); the probes'
        progress records (out/*.jsonl, the largest `bytes` per label). Each object is counted
        once. The engine's node-to-node routing traffic has no byte count and is not included.
U = recorded / (capacity x billed s), capacity from the manifest's instance.type_info or
results/instance-types/<region>.json. Output: results/util-backfill/util-backfill.tsv and its
manifest.json (commit, inputs, generation time, these caveats).
"""
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import util  # noqa: E402

ROOT = util.ROOT
MIB = 1048576
GATES = ("g2", "g3")
RE_TOTAL = re.compile(r"^(\[[^\]]*\] )?ak2-timing\ttotal\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t([0-9.]+)\t([0-9.]+)")
RE_MEM = re.compile(r"^(\[[^\]]*\] )?ak2-engine\tmem\tt_s\t([0-9.]+)\trss_kib\t(-?\d+)\thwm_kib\t(-?\d+)")
RE_LOAD = re.compile(r"^(\[[^\]]*\] )?ak2-engine\tload\t.*\tbytes\t(\d+)")
RE_PARTS = re.compile(r"^(\[[^\]]*\] )?ak2-engine\ts3\tclient\t(\w+)\t.*\tpart_bytes\t(\d+)")
RE_STAGE = re.compile(r"staged (s3://\S+) -> \S+ \((\d+) bytes\)")
RE_STAGE2 = re.compile(r"staged (\S+) bytes=(\d+) in [0-9.]+ s")
RE_INPUTS = re.compile(r"inputs staged and verified: (\d+) files, ([0-9]+)\.?([0-9]*) GB")
RE_COHORT = re.compile(r"stage-cohort: (\S+) staged \((\d+) bytes")
CAVEATS = [
    "Every U is a lower bound: unrecorded processes and windows count as 0.",
    "Rows cannot be compared across arms or run types: their CPU sources differ (engine whole-process "
    "getrusage, upstream per-run getrusage, loadbench per-run getrusage, or none).",
    "Upstream and loadbench memory is a per-process peak RSS (rss_peak_gib), not U_mem: under mmap it is "
    "reclaimable file-backed page cache.",
    "Node-to-node engine traffic has no byte count and is not in net_bytes_lb.",
]


def lines(path):
    if not os.path.exists(path):
        return []
    with open(path, errors="replace") as f:
        return f.read().splitlines()


def cpu_of(d, log):
    """{ours_s, up_s, src, rss_peak_kib, rss_src}; None where not recorded."""
    out = {"ours_s": None, "up_s": None, "src": [], "rss_peak_kib": None, "rss_src": None}

    def addv(k, v):
        out[k] = v if out[k] is None else out[k] + v
    n = 0
    for l in log:
        m = RE_TOTAL.match(l)
        if m:
            addv("ours_s", float(m.group(2)) + float(m.group(3)))
            n += 1
    if n:
        out["src"].append(f"engine getrusage (log): {n} process(es)")
    else:
        for f in sorted(glob.glob(os.path.join(d, "out", "**", "eng-*.stderr"), recursive=True)):
            for l in lines(f):
                m = RE_TOTAL.match(l)
                if m:
                    addv("ours_s", float(m.group(2)) + float(m.group(3)))
                    n += 1
        if n:
            out["src"].append(f"engine getrusage (eng-*.stderr): {n} process(es)")
    k = 0
    for f in sorted(glob.glob(os.path.join(d, "out", "**", "runs.jsonl"), recursive=True)):
        for l in lines(f):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if r.get("kind") == "run" and r.get("user_s") is not None:
                addv("up_s", float(r["user_s"]) + float(r.get("sys_s") or 0))
                k += 1
                if r.get("maxrss") is not None:
                    out["rss_peak_kib"] = max(out["rss_peak_kib"] or 0, float(r["maxrss"]))
                    out["rss_src"] = "upstream maxrss (runs.jsonl)"
    if k:
        out["src"].append(f"upstream getrusage (runs.jsonl): {k} run(s)")
    lu = lo = 0
    for f in sorted(glob.glob(os.path.join(d, "out", "**", "runs.tsv"), recursive=True)):
        rows = lines(f)
        if not rows or "user_s" not in rows[0].split("\t"):
            continue
        h = rows[0].split("\t")
        for l in rows[1:]:
            r = dict(zip(h, l.split("\t")))
            try:
                c = float(r["user_s"]) + float(r.get("sys_s") or 0)
            except (KeyError, ValueError):
                continue
            if r.get("impl") == "upstream":
                addv("up_s", c)
                lu += 1
            else:
                addv("ours_s", c)
                lo += 1
            if util.num(r.get("maxrss")) is not None:
                out["rss_peak_kib"] = max(out["rss_peak_kib"] or 0, float(r["maxrss"]))
                out["rss_src"] = "maxrss (loadbench runs.tsv)"
    if lu or lo:
        out["src"].append(f"loadbench getrusage (runs.tsv): {lu} upstream + {lo} ours run(s)")
    return out


def mem_of(log):
    inv = {}
    for l in log:
        m = RE_MEM.match(l)
        if m and int(m.group(3)) >= 0:
            inv.setdefault(m.group(1) or "", []).append((float(m.group(2)), int(m.group(3)), int(m.group(4))))
    if not inv:
        return None, None, "missing"
    integ, peak, n = 0.0, 0, 0
    for s in inv.values():
        s.sort()
        n += len(s)
        peak = max(peak, max(x[2] for x in s))
        for a, b in zip(s, s[1:]):
            integ += (b[0] - a[0]) * (a[1] + b[1]) / 2.0
    return integ, peak, f"engine rss: {n} sample(s) over {len(inv)} invocation(s)"


def net_of(d, log):
    seen, total, srcs = set(), 0.0, {}

    def add(key, b, src):
        nonlocal total
        if key in seen:
            return
        seen.add(key)
        total += b
        srcs[src] = srcs.get(src, 0) + 1
    for i, l in enumerate(log):
        m = RE_LOAD.match(l)
        if m:
            add(("load", m.group(1), i), int(m.group(2)), "engine shard load")
        m = RE_PARTS.match(l)
        if m:
            add(("parts", m.group(1), m.group(2), i), int(m.group(3)), "engine part uploads")
        m = RE_STAGE.search(l)
        if m:
            add(("obj", os.path.basename(m.group(1)), int(m.group(2))), int(m.group(2)), "ak2_stage")
        m = RE_STAGE2.search(l)
        if m:
            add(("obj", os.path.basename(m.group(1)), int(m.group(2))), int(m.group(2)), "scripted stage")
        m = RE_INPUTS.search(l)
        if m:
            frac = m.group(3)
            gb = float(f"{m.group(2)}.{frac or 0}")
            half = 0.5 * 10 ** (-len(frac)) if frac else 0.5
            add(("inputs", i), max(0.0, gb - half) * 1e9, "inputs staged (GB, rounded down)")
        m = RE_COHORT.search(l)
        if m:
            add(("cohort", m.group(1)), int(m.group(2)), "stage-cohort download")
    for f in sorted(glob.glob(os.path.join(d, "out", "*.jsonl"))):
        best = {}
        for l in lines(f):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if r.get("kind") == "progress" and r.get("bytes") is not None:
                lab = r.get("label", "")
                best[lab] = max(best.get(lab, 0), int(r["bytes"]))
        for lab, b in best.items():
            add(("progress", os.path.basename(f), lab), b, "probe progress")
    if not srcs:
        return None, "missing"
    return total, "logged bytes: " + ", ".join(f"{k} x{v}" for k, v in srcs.items())


def node(d, gate):
    with open(os.path.join(d, "manifest.json")) as f:
        man = json.load(f)
    cap, cap_src = util.capacity(man, man.get("region"))
    log = lines(os.path.join(d, "log", "run.log"))
    cpu = cpu_of(d, log)
    mint, mpk, mem_src = mem_of(log)
    nb, net_src = net_of(d, log)
    arm = "both" if cpu["ours_s"] is not None and cpu["up_s"] is not None else \
        "ours" if cpu["ours_s"] is not None else "upstream" if cpu["up_s"] is not None else "unknown"
    return {"gate": gate, "run": os.path.basename(d), "spec": man.get("spec"), "type": (man.get("instance") or {}).get("type"),
            "billed_s": man.get("billed_seconds"), "cost": man.get("cost_usd"), "cap": cap, "cap_src": cap_src,
            "cpu_ours": cpu["ours_s"], "cpu_up": cpu["up_s"], "cpu_src": " | ".join(cpu["src"]) or "missing", "arm": arm,
            "rss_peak": cpu["rss_peak_kib"], "rss_src": cpu["rss_src"],
            "mem_int": mint, "mem_peak": mpk, "mem_src": mem_src, "net": nb, "net_src": net_src,
            "has_util": os.path.exists(os.path.join(d, "log", "util.tsv")), "exit": (man.get("task") or {}).get("exit_code")}


COLS = ["gate", "scope", "run", "spec", "type", "arm", "nodes", "exit_code", "billed_s", "vcpus", "mem_installed_mib",
        "baseline_gbps", "peak_gbps", "cost_usd", "cpu_s_lb", "cpu_s_ours", "cpu_s_upstream", "U_cpu_lb",
        "mem_used_mean_gib_lb", "U_mem_mean_lb", "mem_peak_gib_lb", "U_mem_peak_lb", "rss_peak_gib", "net_bytes_lb",
        "U_net_baseline_lb", "U_net_peak_lb", "x_cpu_ub", "x_mem_ub", "x_net_baseline_ub",
        "cpu_coverage", "mem_coverage", "net_coverage", "capacity_source", "coverage"]


def u(a, b):
    return None if a is None or not b else a / b


def f6(v):
    return "" if v is None else f"{v:.6f}"


def emit(scope, run, nodes):
    """Sum over the nodes with capacity and a billed window, in numerators and denominators
    alike (one node for a node row). Lower bounds: an included node missing a resource adds 0."""
    inc = [n for n in nodes if n["cap"] and n["billed_s"]]
    exc = [n["run"] for n in nodes if not (n["cap"] and n["billed_s"])]
    vcap = sum(n["cap"]["vcpus"] * n["billed_s"] for n in inc)
    mcap = sum(n["cap"]["memory_mib"] * MIB * n["billed_s"] for n in inc)
    bcap = sum((n["cap"].get("baseline_gbps") or 0) * 1e9 / 8 * n["billed_s"] for n in inc)
    pcap = sum((n["cap"].get("peak_gbps") or 0) * 1e9 / 8 * n["billed_s"] for n in inc)

    def s(k, over=inc):
        xs = [n[k] for n in over if n[k] is not None]
        return (sum(xs) if xs else None), len(xs)
    co, nco = s("cpu_ours")
    cu, ncu = s("cpu_up")
    cpu = None if co is None and cu is None else (co or 0) + (cu or 0)
    mi, nmi = s("mem_int")
    nb, nnb = s("net")
    peaks = [(n["mem_peak"] / (n["cap"]["memory_mib"] * 1024), n["mem_peak"]) for n in inc if n["mem_peak"]]
    rss = [n["rss_peak"] for n in inc if n["rss_peak"]]
    ucpu, umem, unb = u(cpu, vcap), u(mi * 1024 if mi is not None else None, mcap), u(nb, bcap)
    billed = sum(n["billed_s"] for n in inc)

    def cov(k, cnt):
        srcs = sorted({n[k] for n in nodes if n[k]})
        return (f"{cnt}/{len(inc)} node(s): " if len(nodes) > 1 else "") + " | ".join(srcs)
    notes = []
    if exc:
        notes.append(f"excluded (no capacity or billed window): {len(exc)} of {len(nodes)} node(s) "
                     f"({', '.join(exc[:4])}{'...' if len(exc) > 4 else ''})")
    if any(n["has_util"] for n in nodes):
        notes.append("has log/util.tsv: use tables/util.tsv instead")
    notes.append("lower bound: unrecorded processes and windows count as 0")
    c = (inc or nodes)[0]["cap"] or {}
    arms = sorted({n["arm"] for n in nodes})
    return {"gate": nodes[0]["gate"], "scope": scope, "run": run, "spec": nodes[0]["spec"], "type": nodes[0]["type"],
            "arm": ",".join(arms), "nodes": str(len(nodes)),
            "exit_code": ",".join(sorted({str(n["exit"]) for n in nodes})), "billed_s": f"{billed:.0f}",
            "vcpus": str(c.get("vcpus", "")), "mem_installed_mib": str(c.get("memory_mib", "")),
            "baseline_gbps": str(c.get("baseline_gbps", "")), "peak_gbps": str(c.get("peak_gbps", "")),
            "cost_usd": f6(sum(n["cost"] for n in inc if n["cost"] is not None) if any(n["cost"] is not None for n in inc) else None),
            "cpu_s_lb": "" if cpu is None else f"{cpu:.1f}", "cpu_s_ours": "" if co is None else f"{co:.1f}",
            "cpu_s_upstream": "" if cu is None else f"{cu:.1f}", "U_cpu_lb": f6(ucpu),
            "mem_used_mean_gib_lb": "" if mi is None or not billed else f"{mi / billed / MIB:.3f}", "U_mem_mean_lb": f6(umem),
            "mem_peak_gib_lb": f"{max(peaks)[1] / MIB:.3f}" if peaks else "", "U_mem_peak_lb": f6(max(peaks)[0] if peaks else None),
            "rss_peak_gib": f"{max(rss) / MIB:.3f}" if rss else "",
            "net_bytes_lb": "" if nb is None else f"{nb:.0f}", "U_net_baseline_lb": f6(unb), "U_net_peak_lb": f6(u(nb, pcap)),
            "x_cpu_ub": "" if not ucpu else f"{1 / ucpu:.1f}", "x_mem_ub": "" if not umem else f"{1 / umem:.1f}",
            "x_net_baseline_ub": "" if not unb else f"{1 / unb:.1f}",
            "cpu_coverage": cov("cpu_src", max(nco, ncu)),
            "mem_coverage": cov("mem_src", nmi) + (f"; peak RSS only: {', '.join(sorted({n['rss_src'] for n in nodes if n['rss_src']}))}" if rss else ""),
            "net_coverage": cov("net_src", nnb),
            "capacity_source": ",".join(sorted({n["cap_src"].split(" (")[0] for n in nodes})), "coverage": "; ".join(notes)}


def is_run(d):  # a run.sh run dir (not this script's own output dir)
    try:
        with open(os.path.join(d, "manifest.json")) as f:
            return "run_id" in json.load(f)
    except (OSError, ValueError):
        return False


def main():
    rows, nruns, ncoh = [], 0, 0
    for gate in GATES:
        gd = os.path.join(ROOT, "results", gate)
        runs = sorted(d for d in glob.glob(os.path.join(gd, "*")) if is_run(d))
        cohorts = sorted(d for d in glob.glob(os.path.join(gd, "*")) if os.path.exists(os.path.join(d, "cohort.json")))
        member_of = {}
        for c in cohorts:
            with open(os.path.join(c, "cohort.json")) as f:
                cj = json.load(f)
            for m in cj.get("members", []):
                member_of[m.get("run_id") or f"{cj['cohort_id']}-r{m['rank']}"] = os.path.basename(c)
        nodes = {os.path.basename(d): node(d, gate) for d in runs}
        for name, n in nodes.items():
            rows.append(emit("node", name, [n]))
        for c in cohorts:
            mem = [n for name, n in nodes.items() if member_of.get(name) == os.path.basename(c)]
            if mem:
                rows.append(emit("fleet", os.path.basename(c), mem))
        nruns += len(runs)
        ncoh += len(cohorts)
    rows.sort(key=lambda r: (r["gate"], r["run"], r["scope"] != "fleet"))
    out = os.path.join(ROOT, "results", "util-backfill")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "util-backfill.tsv"), "w") as f:
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join("" if r.get(c) is None else str(r[c]) for c in COLS) + "\n")
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    it = os.path.join(ROOT, "results", "instance-types", "us-west-2.json")
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump({"what": "lower-bound utilisation of the results/g2 and results/g3 runs from their recorded logs "
                           "(scripts/lib/util_backfill.py)",
                   "commit": sha, "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "caveats": CAVEATS,
                   "inputs": {"gates": list(GATES), "runs": nruns, "cohorts": ncoh,
                              "instance_types": {"file": "results/instance-types/us-west-2.json",
                                                 "queried_at": json.load(open(it)).get("queried_at") if os.path.exists(it) else None}},
                   "definition": "docs/util.md, 'make util-backfill'"}, f, indent=2)
        f.write("\n")
    print(f"util-backfill: {len(rows)} rows ({nruns} node runs, {ncoh} cohorts in {', '.join(GATES)}) -> {out}/util-backfill.tsv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
