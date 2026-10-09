#!/usr/bin/env python3
"""Utilisation over the billed window (docs/run.md, "Utilisation"; Scott's definition on #25,
2026-10-09). Input: a run dir results/<gate>/<run-id>/ (manifest.json + log/util.tsv, the
sampler's record: scripts/util-sampler.sh) or a cohort dir (cohort.json; its members' run dirs).
Output: <dir>/tables/util.tsv (or --out), one row per scope:

  node        the run's instance over its billed window (launch_time -> terminated_at)
  fleet       the sum over nodes (billed node-seconds, busy vCPU-s, used memory-s, bytes)
  node-phase  per phase of one node (phases from the sampler's phase column; the interval
              between two ticks belongs to the phase of the earlier tick) and the three
              unobservable windows, named in brackets
  fleet-phase the node-phase rows summed by phase name

The three utilisations are reported separately, never combined:
  U_cpu = busy vCPU-s / (vCPUs x billed s); busy = user+nice+system+irq+softirq+steal from
          /proc/stat (guest is inside user; idle and iowait are idle). /proc/stat integrates
          from boot, so CPU between btime and the sampler's first tick is counted.
  U_mem = time-mean (MemTotal - MemAvailable) / installed memory (MemoryInfo.SizeInMiB);
          U_mem_peak = the largest 1 Hz sample / installed. Shmem/tmpfs is inside "used".
  U_net = delta(rx + tx bytes) of the default-route (ENA) interface / (line rate x billed s),
          at NetworkCards[0]'s baseline and peak rate.
Each has its own effective cost, cost_usd / U_r (x_r = 1 / U_r). Windows the sampler cannot see
count as 0% and their durations are columns: launch_time -> btime (all three), btime -> first
tick (memory and network only), last tick -> terminated_at (all three).

Capacity (vCPUs, MiB, Gbps) comes from the manifest's instance.type_info (recorded at launch by
run.sh), else from results/instance-types/<region>.json (scripts/instance-types.sh); the
capacity_source column says which. A missing input leaves its cells empty and is named in
the coverage column; nothing is imputed.
"""
import argparse
import datetime as dt
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIB = 1048576
S_FIELDS = ["t", "phase", "tag", "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal",
            "guest", "guest_nice", "mem_total_kib", "mem_avail_kib", "shmem_kib", "rx_bytes", "tx_bytes",
            "pgfault", "pgmajfault", "cg_usage_usec", "cg_user_usec", "cg_system_usec"]
COLS = ["scope", "node", "phase", "seconds", "vcpus", "mem_installed_mib", "mem_total_kib", "baseline_gbps",
        "peak_gbps", "busy_vcpu_s", "U_cpu", "mem_used_mean_gib", "U_mem_mean", "mem_used_peak_gib", "U_mem_peak",
        "net_bytes", "U_net_baseline", "U_net_peak", "cost_usd", "eff_cost_cpu_usd", "eff_cost_mem_usd",
        "eff_cost_net_baseline_usd", "eff_cost_net_peak_usd", "x_cpu", "x_mem", "x_net_baseline", "x_net_peak",
        "unobs_launch_to_boot_s", "unobs_boot_to_sampler_s", "unobs_last_to_term_s", "task_cgroup_cpu_s",
        "task_cgroup_sys_s", "pgfault", "pgmajfault", "allowance_exceeded", "ticks", "max_gap_s",
        "capacity_source", "coverage"]


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
    """The sampler's record: (header dict, S rows sorted by t, E rows). Malformed lines (a tick
    cut off by a kill) are skipped and counted."""
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


def net(r):
    if r["rx_bytes"] is None or r["tx_bytes"] is None:
        return None
    return r["rx_bytes"] + r["tx_bytes"]


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


def acc():
    return {"seconds": 0.0, "busy_s": 0.0, "mem_int_kib_s": 0.0, "mem_peak_kib": None, "net_bytes": 0.0,
            "pgfault": 0.0, "pgmajfault": 0.0, "cg_s": 0.0, "cg_sys_s": 0.0, "have_mem": False, "have_net": False,
            "have_cg": False, "unobservable": False}


def node_util(man, util_path):
    """One node: a dict with the node totals ('node'), the phase accumulators ('phases', ordered)
    and the coverage notes. Pure function of the manifest and the sampler's record."""
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
           "phases": {}, "order": []}
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
    btime = num(head.get("btime"))
    f, l = rows[0], rows[-1]
    out.update(head=head, ticks=len(rows), t0=f["t"], tN=l["t"], hz=hz, btime=btime,
               ncpu=num(head.get("ncpu")), mem_total_kib=f["mem_total_kib"], iface=head.get("iface"))
    gaps = [b["t"] - a["t"] for a, b in zip(rows, rows[1:])]
    out["max_gap_s"] = max(gaps) if gaps else None
    if btime is None:
        notes.append("no btime in the header")
    if launch is not None and btime is not None:
        out["boot_minus_launch_s"] = btime - launch
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
    out["busy_s"] = busy(l) / hz           # integrated from boot
    out["boot_busy_s"] = busy(f) / hz      # boot -> first tick, inside the total
    # Phase accumulation over tick intervals.
    ph, order = out["phases"], out["order"]

    def get(name):
        if name not in ph:
            ph[name] = acc()
            order.append(name)
        return ph[name]

    for name, secs, kind in (("(launch->boot)", out.get("unobs_pre"), "pre"),
                             ("(boot->first tick)", out.get("unobs_boot"), "boot")):
        if secs is not None:
            a = get(name)
            a["seconds"] = secs
            a["unobservable"] = True
            if kind == "boot":
                a["busy_s"] = out["boot_busy_s"]
    mem_int, mem_peak, have_mem = 0.0, None, False
    for a, b in zip(rows, rows[1:]):
        d = b["t"] - a["t"]
        if d <= 0:
            continue
        p = get(a["phase"])
        p["seconds"] += d
        p["busy_s"] += (busy(b) - busy(a)) / hz
        ua, ub = used_kib(a), used_kib(b)
        if ua is not None and ub is not None:
            m = d * (ua + ub) / 2.0
            p["mem_int_kib_s"] += m
            mem_int += m
            pk = max(ua, ub)
            p["mem_peak_kib"] = pk if p["mem_peak_kib"] is None else max(p["mem_peak_kib"], pk)
            mem_peak = pk if mem_peak is None else max(mem_peak, pk)
            p["have_mem"] = have_mem = True
        na, nb = net(a), net(b)
        if na is not None and nb is not None:
            p["net_bytes"] += max(0.0, nb - na)
            p["have_net"] = True
        for k in ("pgfault", "pgmajfault"):
            x = delta(a, b, k)
            if x is not None:
                p[k] += x
        x = delta(a, b, "cg_usage_usec")
        if x is not None:
            p["cg_s"] += x / 1e6
            p["have_cg"] = True
            y = delta(a, b, "cg_system_usec")
            p["cg_sys_s"] += (y or 0) / 1e6
    if out.get("unobs_post") is not None:
        a = get("(last tick->terminated)")
        a["seconds"] = out["unobs_post"]
        a["unobservable"] = True
    out["mem_int_kib_s"] = mem_int if have_mem else None
    out["mem_peak_kib"] = mem_peak
    if not have_mem:
        notes.append("no memory counters")
    nf, nl = net(f), net(l)
    out["net_bytes"] = (nl - nf) if nf is not None and nl is not None else None
    if out["net_bytes"] is None:
        notes.append(f"no network counters (iface {head.get('iface', '-')})")
    elif out["net_bytes"] < 0:
        notes.append("network counters went backwards (interface reset?): no U_net")
        out["net_bytes"] = None
    cg = delta(f, l, "cg_usage_usec")
    out["cg_s"] = cg / 1e6 if cg is not None else None
    cgs = delta(f, l, "cg_system_usec")
    out["cg_sys_s"] = cgs / 1e6 if cgs is not None else None
    out["pgfault"], out["pgmajfault"] = delta(f, l, "pgfault"), delta(f, l, "pgmajfault")
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
    if kind == "x":
        return "inf" if v == float("inf") else f"{v:.2f}"
    if kind == "usd":
        return "inf" if v == float("inf") else f"{v:.6f}"
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


def row(scope, node, phase, seconds, vcpus, mem_mib, base, peak, busy_s, mem_int, mem_peak_kib, net_b, cost,
        extra, peak_frac=None):
    """One output row from sums: seconds is the window (node: billed s; fleet: node-seconds);
    vcpus / mem_mib / base / peak are per-node capacity x nodes for fleet rows."""
    ucpu = ratio(busy_s, (vcpus or 0) * (seconds or 0)) if vcpus and seconds else None
    inst_b = mem_mib * MIB if mem_mib else None
    umem = ratio(mem_int * 1024 / seconds if mem_int is not None and seconds else None, inst_b)
    upk = peak_frac if peak_frac is not None else ratio(mem_peak_kib * 1024 if mem_peak_kib is not None else None, inst_b)
    unb = ratio(net_b, base * 1e9 / 8 * seconds) if net_b is not None and base and seconds else None
    unp = ratio(net_b, peak * 1e9 / 8 * seconds) if net_b is not None and peak and seconds else None
    r = {"scope": scope, "node": node, "phase": phase, "seconds": fmt(seconds, "s"), "vcpus": fmt(vcpus, "i"),
         "mem_installed_mib": fmt(mem_mib, "i"), "baseline_gbps": fmt(base, ""), "peak_gbps": fmt(peak, ""),
         "busy_vcpu_s": fmt(busy_s, "s"), "U_cpu": fmt(ucpu, "u"),
         "mem_used_mean_gib": fmt(mem_int / seconds / MIB if mem_int is not None and seconds else None, "gib"),
         "U_mem_mean": fmt(umem, "u"),
         "mem_used_peak_gib": fmt(mem_peak_kib / MIB if mem_peak_kib is not None else None, "gib"),
         "U_mem_peak": fmt(upk, "u"), "net_bytes": fmt(net_b, "i"), "U_net_baseline": fmt(unb, "u"),
         "U_net_peak": fmt(unp, "u"), "cost_usd": fmt(cost, "usd")}
    if cost is not None:
        for k, u in (("cpu", ucpu), ("mem", umem), ("net_baseline", unb), ("net_peak", unp)):
            col = "eff_cost_mem_usd" if k == "mem" else f"eff_cost_{k}_usd"
            r[col] = fmt(None if u is None else cost * inv(u), "usd")
    for k, u in (("x_cpu", ucpu), ("x_mem", umem), ("x_net_baseline", unb), ("x_net_peak", unp)):
        r[k] = fmt(inv(u), "x")
    r.update(extra)
    return r


def node_rows(label, n):
    cap = n["cap"] or {}
    v, mm, bg, pg = cap.get("vcpus"), cap.get("memory_mib"), cap.get("baseline_gbps"), cap.get("peak_gbps")
    cov = "; ".join(n["notes"]) if n["notes"] else "full"
    extra = {"mem_total_kib": fmt(n.get("mem_total_kib"), "i"), "unobs_launch_to_boot_s": fmt(n.get("unobs_pre"), "s"),
             "unobs_boot_to_sampler_s": fmt(n.get("unobs_boot"), "s"), "unobs_last_to_term_s": fmt(n.get("unobs_post"), "s"),
             "task_cgroup_cpu_s": fmt(n.get("cg_s"), "s"), "task_cgroup_sys_s": fmt(n.get("cg_sys_s"), "s"),
             "pgfault": fmt(n.get("pgfault"), "i"), "pgmajfault": fmt(n.get("pgmajfault"), "i"),
             "allowance_exceeded": n.get("allowance", ""), "ticks": fmt(n.get("ticks"), "i"),
             "max_gap_s": fmt(n.get("max_gap_s"), "s"), "capacity_source": n["cap_src"], "coverage": cov}
    out = [row("node", label, "(billed window)", n["billed_s"], v, mm, bg, pg, n.get("busy_s"), n.get("mem_int_kib_s"),
               n.get("mem_peak_kib"), n.get("net_bytes"), n["cost"], extra)]
    for name in n["order"]:
        p = n["phases"][name]
        e = {"pgfault": fmt(p["pgfault"], "i"), "pgmajfault": fmt(p["pgmajfault"], "i"),
             "task_cgroup_cpu_s": fmt(p["cg_s"] if p["have_cg"] else None, "s"),
             "task_cgroup_sys_s": fmt(p["cg_sys_s"] if p["have_cg"] else None, "s"),
             "capacity_source": n["cap_src"],
             "coverage": "unobservable: counted as 0%" + (" (CPU from /proc/stat's integration since boot)" if name.startswith("(boot") else "")
             if p["unobservable"] else "ticks"}
        mi = p["mem_int_kib_s"] if p["have_mem"] else (0.0 if p["unobservable"] else None)
        nb = p["net_bytes"] if p["have_net"] else (0.0 if p["unobservable"] else None)
        out.append(row("node-phase", label, name, p["seconds"], v, mm, bg, pg, p["busy_s"], mi, p["mem_peak_kib"], nb, None, e))
    return out


def fleet_rows(nodes):
    """nodes: [(label, node_util)]. Sums over the nodes that have each input; a node without it
    is named in the coverage column."""
    def tot(key):
        s, miss = 0.0, []
        for lab, n in nodes:
            x = n.get(key) if key != "billed_s" else n["billed_s"]
            if x is None:
                miss.append(lab)
            else:
                s += x
        return s, miss
    billed, mb = tot("billed_s")
    caps = [(lab, n["cap"]) for lab, n in nodes if n["cap"]]
    vcap = sum(c["vcpus"] * (n["billed_s"] or 0) for (lab, n) in nodes for c in [n["cap"]] if c)
    mcap = sum(c["memory_mib"] * (n["billed_s"] or 0) for (lab, n) in nodes for c in [n["cap"]] if c)
    bcap = sum((c.get("baseline_gbps") or 0) * (n["billed_s"] or 0) for (lab, n) in nodes for c in [n["cap"]] if c)
    pcap = sum((c.get("peak_gbps") or 0) * (n["billed_s"] or 0) for (lab, n) in nodes for c in [n["cap"]] if c)
    bs, mbs = tot("busy_s")
    mi, mmi = tot("mem_int_kib_s")
    nb, mnb = tot("net_bytes")
    # No node recorded it: empty, not 0.
    bs = None if len(mbs) == len(nodes) else bs
    mi = None if len(mmi) == len(nodes) else mi
    nb = None if len(mnb) == len(nodes) else nb
    mc = [lab for lab, n in nodes if n["cost"] is None]
    cost = sum(n["cost"] for _, n in nodes if n["cost"] is not None) if len(mc) < len(nodes) else None
    peaks = [(n["mem_peak_kib"] * 1024 / (n["cap"]["memory_mib"] * MIB), n["mem_peak_kib"]) for _, n in nodes
             if n.get("mem_peak_kib") is not None and n["cap"]]
    pf = max(peaks)[0] if peaks else None
    pk = max(peaks)[1] if peaks else None
    notes = []
    for what, miss in (("billed window", mb), ("CPU", mbs), ("memory", mmi), ("network", mnb), ("cost", mc)):
        if miss:
            notes.append(f"{what} missing on {len(miss)} of {len(nodes)} node(s) ({', '.join(miss[:6])}{'...' if len(miss) > 6 else ''})"
                         + (": counted as 0" if len(miss) < len(nodes) else ""))
    if len(caps) < len(nodes):
        notes.append(f"capacity missing on {len(nodes) - len(caps)} node(s): excluded from the denominators")
    # Utilisation from capacity-weighted sums: each denominator is the sum of capacity x billed s.
    r = {"scope": "fleet", "node": f"{len(nodes)} node(s)", "phase": "(billed window)", "seconds": fmt(billed, "s"),
         "vcpus": fmt(sum(c["vcpus"] for _, c in caps), "i"), "mem_installed_mib": fmt(sum(c["memory_mib"] for _, c in caps), "i"),
         "baseline_gbps": fmt(sum(c.get("baseline_gbps") or 0 for _, c in caps), ""),
         "peak_gbps": fmt(sum(c.get("peak_gbps") or 0 for _, c in caps), ""),
         "busy_vcpu_s": fmt(bs, "s"), "U_cpu": fmt(ratio(bs, vcap), "u"),
         "mem_used_mean_gib": fmt(mi / billed / MIB if billed and mi is not None else None, "gib"),
         "U_mem_mean": fmt(ratio(mi * 1024, mcap * MIB) if mcap and mi is not None else None, "u"),
         "mem_used_peak_gib": fmt(pk / MIB if pk is not None else None, "gib"), "U_mem_peak": fmt(pf, "u"),
         "net_bytes": fmt(nb, "i"), "U_net_baseline": fmt(ratio(nb, bcap * 1e9 / 8) if bcap else None, "u"),
         "U_net_peak": fmt(ratio(nb, pcap * 1e9 / 8) if pcap else None, "u"), "cost_usd": fmt(cost, "usd")}
    us = {"cpu": ratio(bs, vcap), "mem": ratio(mi * 1024, mcap * MIB) if mcap and mi is not None else None,
          "net_baseline": ratio(nb, bcap * 1e9 / 8) if bcap else None, "net_peak": ratio(nb, pcap * 1e9 / 8) if pcap else None}
    for k, u in us.items():
        if cost is not None:
            r[f"eff_cost_{k}_usd"] = fmt(None if u is None else cost * inv(u), "usd")
        r[f"x_{k}"] = fmt(inv(u), "x")
    for key, col in (("unobs_pre", "unobs_launch_to_boot_s"), ("unobs_boot", "unobs_boot_to_sampler_s"),
                     ("unobs_post", "unobs_last_to_term_s"), ("cg_s", "task_cgroup_cpu_s"), ("cg_sys_s", "task_cgroup_sys_s"),
                     ("pgfault", "pgfault"), ("pgmajfault", "pgmajfault"), ("ticks", "ticks")):
        s, miss = tot(key)
        r[col] = fmt(s if len(miss) < len(nodes) else None, "s" if col.endswith("_s") else "i")
    gaps = [n["max_gap_s"] for _, n in nodes if n.get("max_gap_s") is not None]
    r["max_gap_s"] = fmt(max(gaps) if gaps else None, "s")
    r["capacity_source"] = ",".join(sorted({n["cap_src"].split(" (")[0] for _, n in nodes}))
    r["coverage"] = "; ".join(notes) if notes else "full"
    out = [r]
    # fleet-phase: sums by phase name.
    order, agg = [], {}
    for lab, n in nodes:
        for name in n["order"]:
            if name not in agg:
                agg[name] = {"seconds": 0.0, "busy_s": 0.0, "mem": 0.0, "net": 0.0, "pk": None, "vcap": 0.0,
                             "mcap": 0.0, "bcap": 0.0, "pcap": 0.0, "pgf": 0.0, "pgm": 0.0, "nodes": 0, "unobs": False}
                order.append(name)
            p, a = n["phases"][name], agg[name]
            a["nodes"] += 1
            a["seconds"] += p["seconds"]
            a["busy_s"] += p["busy_s"]
            a["mem"] += p["mem_int_kib_s"]
            a["net"] += p["net_bytes"]
            a["pgf"] += p["pgfault"]
            a["pgm"] += p["pgmajfault"]
            a["unobs"] = a["unobs"] or p["unobservable"]
            if p["mem_peak_kib"] is not None:
                a["pk"] = p["mem_peak_kib"] if a["pk"] is None else max(a["pk"], p["mem_peak_kib"])
            c = n["cap"]
            if c:
                a["vcap"] += c["vcpus"] * p["seconds"]
                a["mcap"] += c["memory_mib"] * MIB * p["seconds"]
                a["bcap"] += (c.get("baseline_gbps") or 0) * 1e9 / 8 * p["seconds"]
                a["pcap"] += (c.get("peak_gbps") or 0) * 1e9 / 8 * p["seconds"]
    for name in order:
        a = agg[name]
        out.append({"scope": "fleet-phase", "node": f"{a['nodes']} node(s)", "phase": name,
                    "seconds": fmt(a["seconds"], "s"), "busy_vcpu_s": fmt(a["busy_s"], "s"),
                    "U_cpu": fmt(ratio(a["busy_s"], a["vcap"]), "u"),
                    "mem_used_mean_gib": fmt(a["mem"] / a["seconds"] / MIB if a["seconds"] else None, "gib"),
                    "U_mem_mean": fmt(ratio(a["mem"] * 1024, a["mcap"]), "u"),
                    "mem_used_peak_gib": fmt(a["pk"] / MIB if a["pk"] is not None else None, "gib"),
                    "net_bytes": fmt(a["net"], "i"), "U_net_baseline": fmt(ratio(a["net"], a["bcap"]), "u"),
                    "U_net_peak": fmt(ratio(a["net"], a["pcap"]), "u"), "pgfault": fmt(a["pgf"], "i"),
                    "pgmajfault": fmt(a["pgm"], "i"),
                    "coverage": "unobservable: counted as 0%" if a["unobs"] else "ticks"})
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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir", help="results/<gate>/<run-id> (manifest.json) or a cohort dir (cohort.json)")
    ap.add_argument("--out", help="output TSV (default <dir>/tables/util.tsv)")
    a = ap.parse_args(argv)
    d = a.dir.rstrip("/")
    out = a.out or os.path.join(d, "tables", "util.tsv")
    if os.path.exists(os.path.join(d, "manifest.json")):
        n = node_util(load(d), os.path.join(d, "log", "util.tsv"))
        rows = node_rows(os.path.basename(d), n)
        rows = rows[:1] + fleet_rows([(os.path.basename(d), n)])[:1] + rows[1:]
    elif os.path.exists(os.path.join(d, "cohort.json")):
        with open(os.path.join(d, "cohort.json")) as f:
            c = json.load(f)
        nodes = []
        for m in c.get("members", []):
            md = os.path.join(os.path.dirname(d), m.get("run_id") or f"{c['cohort_id']}-r{m['rank']}")
            lab = f"r{m['rank']}"
            if os.path.exists(os.path.join(md, "manifest.json")):
                nodes.append((lab, node_util(load(md), os.path.join(md, "log", "util.tsv"))))
            else:
                nodes.append((lab, {"billed_s": None, "cap": None, "cap_src": "missing", "cost": None,
                                    "notes": ["no member manifest"], "phases": {}, "order": []}))
        rows = []
        for lab, n in nodes:
            rows += node_rows(lab, n)[:1]
        rows += fleet_rows(nodes)
    else:
        print(f"util.py: {d} has neither manifest.json nor cohort.json", file=sys.stderr)
        return 2
    write(rows, out)
    print(f"util.py: wrote {out} ({len(rows)} rows)")
    for r in rows:
        if r["scope"] in ("node", "fleet") and (r["scope"] == "fleet" or len(rows) < 40):
            print(f"util.py: {r['scope']} {r['node']}: U_cpu {r.get('U_cpu') or '-'} U_mem {r.get('U_mem_mean') or '-'} "
                  f"(peak {r.get('U_mem_peak') or '-'}) U_net {r.get('U_net_baseline') or '-'}/{r.get('U_net_peak') or '-'} "
                  f"[{r.get('coverage')}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
