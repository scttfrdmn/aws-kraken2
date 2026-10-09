#!/usr/bin/env python3
"""Utilisation over the billed window (docs/run.md, "Utilisation"; Scott's definition on #25,
2026-10-09). Input: a run dir results/<gate>/<run-id>/ (manifest.json + log/util.tsv, the
sampler's record: scripts/util-sampler.sh) or a cohort dir (cohort.json; its members' run dirs).
Output: <dir>/tables/util.tsv (or --out) and a sidecar util.json beside it (util.py's commit,
every input file with its sha256). One row per scope:

  node        one instance over its billed window (launch_time -> terminated_at); in a cohort
              the node column is the member's run_id
  fleet       the sum over the nodes that have capacity and a billed window (numerators and
              denominators over the same nodes; any other node is excluded and named)
  node-phase  per phase of one node (the interval between two ticks belongs to the phase of the
              earlier tick; ak2_phase ticks at each phase start) and the three unobservable
              windows, named in brackets
  fleet-phase the node-phase rows summed by phase name, over the fleet's nodes

The three utilisations are reported separately, never combined:
  U_cpu = busy vCPU-s / (vCPUs x billed s); busy = user+nice+system+irq+softirq+steal from
          /proc/stat (guest is inside user; idle and iowait are idle).
  U_mem = time-mean (MemTotal - MemAvailable) / installed memory (MemoryInfo.SizeInMiB);
          U_mem_peak = the largest sample / installed. Shmem/tmpfs is inside "used". Memory is a
          gauge: it is integrated (trapezoid) only over tick intervals no longer than 2.5 x the
          sampling period; a longer interval is a gap, counted as 0 and reported (mem_gap_s).
  U_net = (rx + tx bytes) of the default-route (ENA) interface / (line rate x billed s), at
          NetworkCards[0]'s baseline and peak rate; U_net_rx and U_net_tx are each direction
          alone over the same line rate.
CPU and network are counters that run from boot (/proc/stat, /sys/class/net/*/statistics), so
both are counted from btime, the boot -> first tick window included. Memory is the only resource
whose boot -> first tick window counts as 0. launch_time -> btime and last tick -> terminated_at
count as 0 for all three. The three window durations are columns.
Each U has its own effective cost, cost_usd / U (x = 1 / U). A missing input leaves its cells
empty and is named in coverage; counters that go backwards give None plus a note, never 0.
Capacity (vCPUs, MiB, Gbps) comes from the manifest's instance.type_info (recorded at launch by
run.sh), else from results/instance-types/<region>.json (scripts/instance-types.sh).
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIB = 1048576
GAP_FACTOR = 2.5
S_FIELDS = ["t", "phase", "tag", "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal",
            "guest", "guest_nice", "mem_total_kib", "mem_avail_kib", "shmem_kib", "rx_bytes", "tx_bytes",
            "pgfault", "pgmajfault", "cg_usage_usec", "cg_user_usec", "cg_system_usec"]
COLS = ["scope", "node", "phase", "seconds", "vcpus", "mem_installed_mib", "mem_total_kib", "baseline_gbps",
        "peak_gbps", "busy_vcpu_s", "U_cpu", "mem_used_mean_gib", "U_mem_mean", "mem_used_peak_gib", "U_mem_peak",
        "mem_gap_s", "net_bytes", "U_net_baseline", "U_net_peak", "rx_bytes", "tx_bytes", "U_net_rx_baseline",
        "U_net_rx_peak", "U_net_tx_baseline", "U_net_tx_peak", "cost_usd", "eff_cost_cpu_usd", "eff_cost_mem_usd",
        "eff_cost_net_baseline_usd", "eff_cost_net_peak_usd", "x_cpu", "x_mem", "x_net_baseline", "x_net_peak",
        "unobs_launch_to_boot_s", "unobs_boot_to_sampler_s", "unobs_last_to_term_s", "task_cgroup_cpu_s",
        "task_cgroup_sys_s", "pgfault", "pgmajfault", "allowance_exceeded", "ticks", "max_gap_s",
        "capacity_source", "coverage"]
NUMS = ["busy_s", "mem_int", "rx", "tx", "mem_gap_s", "pgfault", "pgmajfault", "cg_s", "cg_sys_s"]


def ts(s):
    """ISO-8601 (manifest style: ...+00:00, ...Z, optional fraction) -> epoch seconds."""
    if not s:
        return None
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_util(path):
    """The sampler's record: (header dict, S rows sorted by t, E rows, malformed count). Malformed
    lines (a tick cut off by a kill) are skipped and counted."""
    head, rows, eth, bad = {}, [], [], 0
    with open(path, errors="replace") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if p[0] == "H" and len(p) >= 3:
                head[p[1]] = p[2]
            elif p[0] == "S" and len(p) == len(S_FIELDS) + 1:
                r = {"phase": p[2], "tag": p[3]}
                for k, v in zip(S_FIELDS, p[1:]):
                    if k not in ("phase", "tag"):
                        r[k] = num(v)
                if r["t"] is None or r["user"] is None:
                    bad += 1
                    continue
                rows.append(r)
            elif p[0] == "E" and len(p) == 5:
                eth.append({"t": num(p[1]), "when": p[2], "name": p[3], "value": p[4]})
            elif line.strip():
                bad += 1
    rows.sort(key=lambda r: r["t"])
    return head, rows, eth, bad


def busy(r):
    return sum(r[k] or 0 for k in ("user", "nice", "system", "irq", "softirq", "steal"))


def used_kib(r):
    if r["mem_total_kib"] is None or r["mem_avail_kib"] is None:
        return None
    return r["mem_total_kib"] - r["mem_avail_kib"]


def delta(a, b, k):
    return None if a[k] is None or b[k] is None else b[k] - a[k]


def capacity(man, region):
    ti = (man.get("instance") or {}).get("type_info")
    if ti and ti.get("vcpus"):
        return ti, "manifest"
    typ = (man.get("instance") or {}).get("type")
    f = os.path.join(ROOT, "results", "instance-types", f"{region or 'us-west-2'}.json")
    if typ and os.path.exists(f):
        with open(f) as fh:
            d = json.load(fh)
        if typ in d.get("types", {}):
            return d["types"][typ], f"results/instance-types/{os.path.basename(f)} ({d.get('queried_at', '?')})"
    return None, "missing"


def acc(seconds=0.0, unobservable=False):
    """A sum over a window. None in a numeric field = not recorded."""
    a = {k: None for k in NUMS}
    a.update(seconds=seconds, peak_kib=None, unobservable=unobservable, notes=[])
    return a


def add(a, k, v):
    if v is not None:
        a[k] = v if a[k] is None else a[k] + v


def node_util(man, util_path):
    """One node: totals ('tot', an acc over the billed window), the phase accs ('phases', in
    order of first appearance), capacity, cost and coverage notes. A pure function of the
    manifest and the sampler's record."""
    notes = []
    inst = man.get("instance") or {}
    launch, term = ts(inst.get("launch_time") or man.get("start")), ts(inst.get("terminated_at") or man.get("stop"))
    billed = man.get("billed_seconds")
    if billed is None and launch is not None and term is not None:
        billed = term - launch
    cap, cap_src = capacity(man, man.get("region"))
    if cap is None:
        notes.append("no capacity (instance.type_info / results/instance-types)")
    if billed is None or launch is None or term is None:
        notes.append("no billed window (launch_time/terminated_at)")
    out = {"billed_s": billed, "cap": cap, "cap_src": cap_src, "cost": man.get("cost_usd"), "notes": notes,
           "tot": acc(billed or 0.0), "phases": {}, "order": []}
    if not util_path or not os.path.exists(util_path):
        notes.append("no log/util.tsv (run predates the sampler, or it never streamed)")
        return out
    head, rows, eth, bad = parse_util(util_path)
    if bad:
        notes.append(f"{bad} malformed line(s) skipped")
    if len(rows) < 2:
        notes.append(f"{len(rows)} tick(s): too few")
        return out
    hz = num(head.get("clk_tck")) or 100.0
    every = num(head.get("every")) or 1.0
    gap_limit = GAP_FACTOR * every
    btime = num(head.get("btime"))
    f, l = rows[0], rows[-1]
    out.update(ticks=len(rows), mem_total_kib=f["mem_total_kib"], ncpu=num(head.get("ncpu")))
    gaps = [b["t"] - a["t"] for a, b in zip(rows, rows[1:])]
    out["max_gap_s"] = max(gaps) if gaps else None
    if btime is None:
        notes.append("no btime in the header: the boot window is not counted")
    if launch is not None and btime is not None:
        out["unobs_pre"] = max(0.0, btime - launch)
        if btime < launch:
            notes.append(f"btime is {launch - btime:.1f} s before launch_time (clock skew); window taken as 0")
    if btime is not None:
        out["unobs_boot"] = f["t"] - btime
    if term is not None:
        out["unobs_post"] = max(0.0, term - l["t"])
        if l["t"] > term:
            notes.append(f"last tick {l['t'] - term:.1f} s after terminated_at")
    if l.get("tag") != "final":
        notes.append("no final tick (ak2_finish did not run, or its push was lost)")
    ph, order = out["phases"], out["order"]

    def get(name, **kw):
        if name not in ph:
            ph[name] = acc(**kw)
            order.append(name)
        return ph[name]

    tot = out["tot"]
    if out.get("unobs_pre") is not None:
        get("(launch->boot)", seconds=out["unobs_pre"], unobservable=True)
    if btime is not None:
        # Counters from boot: CPU and network are integrated over this window; memory is not.
        b = get("(boot->first tick)", seconds=out["unobs_boot"], unobservable=True)
        add(b, "busy_s", busy(f) / hz)
        add(b, "rx", f["rx_bytes"])
        add(b, "tx", f["tx_bytes"])
        for k in ("busy_s", "rx", "tx"):
            add(tot, k, b[k])
    reset = {"rx": False, "tx": False}
    for a, b in zip(rows, rows[1:]):
        d = b["t"] - a["t"]
        if d <= 0:
            continue
        p = get(a["phase"])
        p["seconds"] += d
        for k, v in (("busy_s", (busy(b) - busy(a)) / hz), ("pgfault", delta(a, b, "pgfault")),
                     ("pgmajfault", delta(a, b, "pgmajfault"))):
            add(p, k, v)
            add(tot, k, v)
        x = delta(a, b, "cg_usage_usec")
        if x is not None:
            for k, v in (("cg_s", x / 1e6), ("cg_sys_s", (delta(a, b, "cg_system_usec") or 0) / 1e6)):
                add(p, k, v)
                add(tot, k, v)
        for k, col in (("rx", "rx_bytes"), ("tx", "tx_bytes")):
            x = delta(a, b, col)
            if x is not None and x < 0:
                reset[k] = True
                p["notes"].append(f"{k} counter went backwards at t={b['t']:.0f}: no {k} bytes")
                p[k] = float("nan")
            elif x is not None:
                add(p, k, x)
                add(tot, k, x)
        ua, ub = used_kib(a), used_kib(b)
        if ua is not None and ub is not None:
            pk = max(ua, ub)
            for q in (p, tot):
                q["peak_kib"] = pk if q["peak_kib"] is None else max(q["peak_kib"], pk)
            if d <= gap_limit:
                add(p, "mem_int", d * (ua + ub) / 2.0)
                add(tot, "mem_int", d * (ua + ub) / 2.0)
                add(p, "mem_gap_s", 0.0)
                add(tot, "mem_gap_s", 0.0)
            else:
                add(p, "mem_gap_s", d)
                add(tot, "mem_gap_s", d)
                add(p, "mem_int", 0.0)
                add(tot, "mem_int", 0.0)
    if out.get("unobs_post") is not None:
        get("(last tick->terminated)", seconds=out["unobs_post"], unobservable=True)
    for name, p in ph.items():
        if p["unobservable"]:
            # Not seen by the sampler: memory 0; CPU and network 0 except the boot window, whose
            # counters are integrated from boot (left None there if the counters were absent).
            p["mem_int"] = 0.0
            if not name.startswith("(boot"):
                for k in ("busy_s", "rx", "tx"):
                    p[k] = 0.0
    for k in ("rx", "tx"):
        if reset[k]:
            tot[k] = None
            notes.append(f"{k} counter went backwards (interface reset?): no {k}, so no U_net")
        for p in ph.values():
            if p[k] is not None and p[k] != p[k]:  # nan marks a reset in this phase
                p[k] = None
    if tot["mem_int"] is None:
        notes.append("no memory counters")
    if tot["mem_gap_s"]:
        n = sum(1 for g in gaps if g > gap_limit)
        notes.append(f"memory: {n} gap(s) > {gap_limit:g} s totalling {tot['mem_gap_s']:.1f} s counted as 0")
    if tot["rx"] is None and tot["tx"] is None and not any(reset.values()):
        notes.append(f"no network counters (iface {head.get('iface', '-')})")
    # ethtool allowances: end - start per counter.
    st = {e["name"]: e["value"] for e in eth if e["when"] == "start"}
    en = {e["name"]: e["value"] for e in eth if e["when"] == "end"}
    parts = []
    for k in sorted(set(st) | set(en)):
        if k == "none":
            parts.append(f"{st.get(k) or en.get(k)}")
            continue
        a, b = num(st.get(k)), num(en.get(k))
        parts.append(f"{k}={int(b - a)}" if a is not None and b is not None else f"{k}=start:{st.get(k, '-')},end:{en.get(k, '-')}")
    out["allowance"] = ";".join(dict.fromkeys(parts)) if parts else "not recorded"
    if out.get("ncpu") and cap and cap.get("vcpus") and int(out["ncpu"]) != int(cap["vcpus"]):
        notes.append(f"/proc/stat shows {int(out['ncpu'])} CPUs, type_info {cap['vcpus']} vCPUs")
    return out


def ratio(a, b):
    return None if a is None or not b else a / b


def fmt(v, kind):
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if kind == "u":
        return f"{v:.6f}"
    if kind in ("x", "usd"):
        return "inf" if v == float("inf") else (f"{v:.2f}" if kind == "x" else f"{v:.6f}")
    if kind == "s":
        return f"{v:.1f}"
    if kind == "gib":
        return f"{v:.3f}"
    if kind == "i":
        return str(int(round(v)))
    return str(v)


def inv(u):
    if u is None:
        return None
    return float("inf") if u == 0 else 1.0 / u


def denom(cap, seconds):
    """Capacity x seconds: vCPU-s, byte-s of installed memory, bytes at the baseline and peak rate."""
    if not cap or not seconds:
        return None
    return {"vcpu_s": cap["vcpus"] * seconds, "mem_bs": cap["memory_mib"] * MIB * seconds,
            "baseline_b": (cap.get("baseline_gbps") or 0) * 1e9 / 8 * seconds,
            "peak_b": (cap.get("peak_gbps") or 0) * 1e9 / 8 * seconds}


def row(scope, node, phase, a, den, shown, cost=None, peak_frac=None, extra=None):
    """One output row from an acc and its denominators. shown: capacity columns to print
    (vcpus, mem_mib, baseline, peak)."""
    den = den or {}
    s = a["seconds"]
    net = None if a["rx"] is None or a["tx"] is None else a["rx"] + a["tx"]
    ucpu = ratio(a["busy_s"], den.get("vcpu_s"))
    umem = ratio(a["mem_int"] * 1024 if a["mem_int"] is not None else None, den.get("mem_bs"))
    upk = peak_frac if peak_frac is not None else ratio(
        a["peak_kib"] * 1024 if a["peak_kib"] is not None else None, den.get("mem_bs") / s if den.get("mem_bs") and s else None)
    un = {f"U_net_{w}": ratio(net, den.get(f"{w}_b")) for w in ("baseline", "peak")}
    for dirn in ("rx", "tx"):
        for w in ("baseline", "peak"):
            un[f"U_net_{dirn}_{w}"] = ratio(a[dirn], den.get(f"{w}_b"))
    r = {"scope": scope, "node": node, "phase": phase, "seconds": fmt(s, "s"), "vcpus": fmt(shown[0], "i"),
         "mem_installed_mib": fmt(shown[1], "i"), "baseline_gbps": fmt(shown[2], ""), "peak_gbps": fmt(shown[3], ""),
         "busy_vcpu_s": fmt(a["busy_s"], "s"), "U_cpu": fmt(ucpu, "u"),
         "mem_used_mean_gib": fmt(a["mem_int"] / s / MIB if a["mem_int"] is not None and s else None, "gib"),
         "U_mem_mean": fmt(umem, "u"),
         "mem_used_peak_gib": fmt(a["peak_kib"] / MIB if a["peak_kib"] is not None else None, "gib"),
         "U_mem_peak": fmt(upk, "u"), "mem_gap_s": fmt(a["mem_gap_s"], "s"), "net_bytes": fmt(net, "i"),
         "rx_bytes": fmt(a["rx"], "i"), "tx_bytes": fmt(a["tx"], "i"), "cost_usd": fmt(cost, "usd"),
         "task_cgroup_cpu_s": fmt(a["cg_s"], "s"), "task_cgroup_sys_s": fmt(a["cg_sys_s"], "s"),
         "pgfault": fmt(a["pgfault"], "i"), "pgmajfault": fmt(a["pgmajfault"], "i")}
    r.update({k: fmt(v, "u") for k, v in un.items()})
    us = {"cpu": ucpu, "mem": umem, "net_baseline": un["U_net_baseline"], "net_peak": un["U_net_peak"]}
    for k, u in us.items():
        if cost is not None:
            r[f"eff_cost_{k}_usd"] = fmt(None if u is None else cost * inv(u), "usd")
        r[f"x_{k}"] = fmt(inv(u), "x")
    r.update(extra or {})
    return r


def capshow(cap):
    c = cap or {}
    return (c.get("vcpus"), c.get("memory_mib"), c.get("baseline_gbps"), c.get("peak_gbps"))


def phase_cov(name, p):
    if p["unobservable"]:
        if name.startswith("(boot"):
            return "unobservable: memory counted as 0%; CPU and network from the counters' integration since boot"
        return "unobservable: counted as 0%"
    return "; ".join(p["notes"]) if p["notes"] else "ticks"


def node_rows(label, n):
    cap = n["cap"]
    extra = {"mem_total_kib": fmt(n.get("mem_total_kib"), "i"), "unobs_launch_to_boot_s": fmt(n.get("unobs_pre"), "s"),
             "unobs_boot_to_sampler_s": fmt(n.get("unobs_boot"), "s"), "unobs_last_to_term_s": fmt(n.get("unobs_post"), "s"),
             "allowance_exceeded": n.get("allowance", ""), "ticks": fmt(n.get("ticks"), "i"),
             "max_gap_s": fmt(n.get("max_gap_s"), "s"), "capacity_source": n["cap_src"],
             "coverage": "; ".join(n["notes"]) if n["notes"] else "full"}
    out = [row("node", label, "(billed window)", n["tot"], denom(cap, n["billed_s"]), capshow(cap), n["cost"], extra=extra)]
    for name in n["order"]:
        p = n["phases"][name]
        out.append(row("node-phase", label, name, p, denom(cap, p["seconds"]), capshow(cap),
                       extra={"capacity_source": n["cap_src"], "coverage": phase_cov(name, p)}))
    return out


def fleet_rows(nodes):
    """nodes: [(label, node_util)]. Only nodes with capacity and a billed window enter the fleet,
    in numerators and denominators alike; the others are named. Within the fleet a node that did
    not record a resource adds 0 to it, and is named."""
    inc = [(lab, n) for lab, n in nodes if n["cap"] and n["billed_s"]]
    exc = [lab for lab, n in nodes if not (n["cap"] and n["billed_s"])]
    tot = acc(sum(n["billed_s"] for _, n in inc))
    den = {"vcpu_s": 0.0, "mem_bs": 0.0, "baseline_b": 0.0, "peak_b": 0.0}
    miss = {k: [] for k in ("busy_s", "mem_int", "rx", "tx")}
    for lab, n in inc:
        for k, v in denom(n["cap"], n["billed_s"]).items():
            den[k] += v
        for k in NUMS:
            if n["tot"][k] is None:
                if k in miss:
                    miss[k].append(lab)
            else:
                add(tot, k, n["tot"][k])
    for k in ("busy_s", "mem_int", "rx", "tx"):   # recorded by none: empty, not 0
        if inc and len(miss[k]) == len(inc):
            tot[k] = None
    peaks = [(n["tot"]["peak_kib"] * 1024 / (n["cap"]["memory_mib"] * MIB), n["tot"]["peak_kib"]) for _, n in inc
             if n["tot"]["peak_kib"] is not None]
    if peaks:
        tot["peak_kib"] = max(peaks)[1]
    costs = [n["cost"] for _, n in inc if n["cost"] is not None]
    nocost = [lab for lab, n in inc if n["cost"] is None]

    def names(ls):
        return f"{', '.join(ls[:6])}{'...' if len(ls) > 6 else ''}"
    notes = []
    if exc:
        notes.append(f"excluded (no capacity or billed window): {len(exc)} of {len(nodes)} node(s) ({names(exc)})")
    for what, ks in (("CPU", ["busy_s"]), ("memory", ["mem_int"]), ("network", ["rx", "tx"])):
        m = sorted(set(sum((miss[k] for k in ks), [])))
        if m:
            notes.append(f"{what} missing on {len(m)} of {len(inc)} node(s) ({names(m)})"
                         + (": counted as 0" if len(m) < len(inc) else ""))
    if nocost:
        notes.append(f"cost missing on {len(nocost)} node(s) ({names(nocost)})")
    nn = [f"{lab}: {'; '.join(n['notes'])}" for lab, n in nodes if n["notes"]]
    if nn:
        notes.append("node notes: " + " | ".join(nn[:8]) + (f" | ... ({len(nn) - 8} more)" if len(nn) > 8 else ""))
    caps = [n["cap"] for _, n in inc]
    shown = (sum(c["vcpus"] for c in caps), sum(c["memory_mib"] for c in caps),
             sum(c.get("baseline_gbps") or 0 for c in caps), sum(c.get("peak_gbps") or 0 for c in caps)) if caps else (None,) * 4

    def tsum(key, kind):
        xs = [n.get(key) for _, n in inc if n.get(key) is not None]
        return fmt(sum(xs) if xs else None, kind)
    gaps = [n["max_gap_s"] for _, n in inc if n.get("max_gap_s") is not None]
    extra = {"unobs_launch_to_boot_s": tsum("unobs_pre", "s"), "unobs_boot_to_sampler_s": tsum("unobs_boot", "s"),
             "unobs_last_to_term_s": tsum("unobs_post", "s"), "ticks": tsum("ticks", "i"),
             "max_gap_s": fmt(max(gaps) if gaps else None, "s"),
             "capacity_source": ",".join(sorted({n["cap_src"].split(" (")[0] for _, n in nodes})),
             "coverage": "; ".join(notes) if notes else "full"}
    out = [row("fleet", f"{len(inc)} of {len(nodes)} node(s)", "(billed window)", tot, den if inc else None, shown,
               sum(costs) if costs else None, peak_frac=max(peaks)[0] if peaks else None, extra=extra)]
    # fleet-phase: sums by phase name over the fleet's nodes.
    order, agg, pden, pnodes = [], {}, {}, {}
    for lab, n in inc:
        for name in n["order"]:
            p = n["phases"][name]
            if name not in agg:
                agg[name] = acc(unobservable=p["unobservable"])
                pden[name] = {"vcpu_s": 0.0, "mem_bs": 0.0, "baseline_b": 0.0, "peak_b": 0.0}
                pnodes[name] = 0
                order.append(name)
            a = agg[name]
            pnodes[name] += 1
            a["seconds"] += p["seconds"]
            for k in NUMS:
                add(a, k, p[k])
            if p["peak_kib"] is not None:
                a["peak_kib"] = p["peak_kib"] if a["peak_kib"] is None else max(a["peak_kib"], p["peak_kib"])
            a["notes"] += [f"{lab}: {x}" for x in p["notes"]]
            for k, v in (denom(n["cap"], p["seconds"]) or {}).items():
                pden[name][k] += v
    for name in order:
        out.append(row("fleet-phase", f"{pnodes[name]} node(s)", name, agg[name], pden[name], (None,) * 4,
                       extra={"coverage": phase_cov(name, agg[name])}))
    return out


def write(rows, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in COLS) + "\n")


def load(d):
    with open(os.path.join(d, "manifest.json")) as f:
        return json.load(f)


def sidecar(out, inputs):
    """util.json beside the table: util.py's commit and every input with its sha256."""
    def git(*a):
        try:
            return subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True, timeout=20).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""
    files = []
    for p in inputs:
        if os.path.exists(p):
            with open(p, "rb") as f:
                b = f.read()
            files.append({"path": os.path.relpath(os.path.abspath(p), ROOT), "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()})
        else:
            files.append({"path": os.path.relpath(os.path.abspath(p), ROOT), "missing": True})
    side = os.path.splitext(out)[0] + ".json"
    with open(side, "w") as f:
        json.dump({"table": os.path.relpath(os.path.abspath(out), ROOT), "generator": "scripts/lib/util.py",
                   "commit": git("rev-parse", "HEAD") or None,
                   "util_py_dirty": bool(git("status", "--porcelain", "--", "scripts/lib/util.py")),
                   "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "inputs": files}, f, indent=2)
        f.write("\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir", help="results/<gate>/<run-id> (manifest.json) or a cohort dir (cohort.json)")
    ap.add_argument("--out", help="output TSV (default <dir>/tables/util.tsv); util.json goes beside it")
    a = ap.parse_args(argv)
    d = a.dir.rstrip("/")
    out = a.out or os.path.join(d, "tables", "util.tsv")
    it = os.path.join(ROOT, "results", "instance-types", "us-west-2.json")
    if os.path.exists(os.path.join(d, "manifest.json")):
        n = node_util(load(d), os.path.join(d, "log", "util.tsv"))
        rows = node_rows(os.path.basename(d), n)
        rows = rows[:1] + fleet_rows([(os.path.basename(d), n)])[:1] + rows[1:]
        inputs = [os.path.join(d, "manifest.json"), os.path.join(d, "log", "util.tsv")]
    elif os.path.exists(os.path.join(d, "cohort.json")):
        with open(os.path.join(d, "cohort.json")) as f:
            c = json.load(f)
        nodes, inputs = [], [os.path.join(d, "cohort.json")]
        for m in c.get("members", []):
            rid = m.get("run_id") or f"{c['cohort_id']}-r{m['rank']}"
            md = os.path.join(os.path.dirname(d), rid)
            inputs += [os.path.join(md, "manifest.json"), os.path.join(md, "log", "util.tsv")]
            if os.path.exists(os.path.join(md, "manifest.json")):
                nodes.append((rid, node_util(load(md), os.path.join(md, "log", "util.tsv"))))
            else:
                nodes.append((rid, {"billed_s": None, "cap": None, "cap_src": "missing", "cost": None, "tot": acc(),
                                    "notes": ["no member manifest"], "phases": {}, "order": []}))
        rows = []
        for lab, n in nodes:
            rows += node_rows(lab, n)[:1]
        rows += fleet_rows(nodes)
    else:
        print(f"util.py: {d} has neither manifest.json nor cohort.json", file=sys.stderr)
        return 2
    write(rows, out)
    sidecar(out, inputs + [it])
    print(f"util.py: wrote {out} ({len(rows)} rows) and its util.json")
    for r in rows:
        if r["scope"] in ("node", "fleet") and (r["scope"] == "fleet" or len(rows) < 40):
            print(f"util.py: {r['scope']} {r['node']}: U_cpu {r.get('U_cpu') or '-'} U_mem {r.get('U_mem_mean') or '-'} "
                  f"(peak {r.get('U_mem_peak') or '-'}) U_net {r.get('U_net_baseline') or '-'}/{r.get('U_net_peak') or '-'} "
                  f"[{r.get('coverage')}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
