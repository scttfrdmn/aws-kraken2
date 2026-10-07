#!/usr/bin/env python3
"""Summary of one make g2 result dir (docs/g2.md). Usage: g2summary.py RESULT_DIR

Reads runs.jsonl, inputs.json and manifest.json; writes summary.tsv (one row per cell =
regime, input, state, threads: n, median/min/max of classify_s, wall_s, load_s, throughput),
signatures.tsv (per cell, medians of each candidate's signature) and summary.md (the same as
tables, the per-regime ladder with speedup, step efficiency and resolution, the gz-vs-plain
comparison, and one table per candidate saying what was seen and whether the probe could have
resolved it). Every number comes from runs.jsonl.

Resolution rules (Law 4: a null result counts only if the probe could have shown the effect):
- blocks: classify.cc hands out 8 MiB input blocks; with B blocks, T threads have at most
  min(T, B) busy, and the makespan is ceil(B/T) block-times against B/T ideal. A rung with
  B < 2T cannot resolve scaling; its quantization factor ceil(B/T)/(B/T) is shown.
- a ladder step is "resolved" when the two rungs' min-max classify_s ranges are separated.
- queue depth: needs disk reads in the window (>= 1000 read IOs).
- read-around: needs >= 1000 major faults in the window.
- critical sections: needs >= 50 sampler samples per rung, at >= 2 thread counts.
- DRAM/TLB: needs perf cycles/instructions (and dTLB events) in the window.
- gzip: needs the same regime/state/threads run with both -gz and -fq inputs.
"""
import datetime
import json
import math
import os
import statistics
import subprocess
import sys


def _git(*a):
    try:
        return subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(__file__))] + list(a),
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


# The generator's own identity, cited in every summary next to the run's commit.
GEN_COMMIT = _git("rev-parse", "HEAD") or "unknown"
GEN_DIRTY = bool(_git("status", "--porcelain", "--", "g2summary.py"))
GEN_AT = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def rng(xs):
    xs = [x for x in xs if x is not None]
    return (min(xs), max(xs)) if xs else (None, None)


def f(x, n=3):
    if x is None:
        return "-"
    if isinstance(x, float):
        if x != 0 and abs(x) < 10 ** -n:
            return "%.2e" % x
        return ("%." + str(n) + "f") % x
    return str(x)


def disk_main(r):
    """The array device if there is one (md*), else the sum over the listed devices."""
    d = r.get("disks") or {}
    if not d:
        return None
    md = {k: v for k, v in d.items() if k.startswith("md")}
    use = md or d
    agg = {"rd_ios": sum(v["rd_ios"] for v in use.values()),
           "rd_bytes": sum(v["rd_bytes"] for v in use.values()),
           "aqu_sz": sum((v["aqu_sz"] or 0) for v in use.values()),
           "util": max((v["util"] or 0) for v in use.values())}
    w = r.get("window_s") or 0
    agg["r_iops"] = agg["rd_ios"] / w if w else None
    agg["rd_mib_s"] = agg["rd_bytes"] / 1048576.0 / w if w else None
    agg["kib_per_io"] = agg["rd_bytes"] / 1024.0 / agg["rd_ios"] if agg["rd_ios"] else None
    # member devices (for md arrays the per-member queue is what the NVMe sees)
    agg["member_aqu_sz"] = sum((v["aqu_sz"] or 0) for k, v in d.items() if not k.startswith("md")) if md else agg["aqu_sz"]
    return agg


def sig(r):
    s = {}
    dm = disk_main(r)
    vm = r.get("vmstat") or {}
    w = r.get("window_s")
    T = r["threads"]
    s["aqu_sz"] = dm["member_aqu_sz"] if dm else None
    s["aqu_per_thread"] = (dm["member_aqu_sz"] / T) if dm else None
    s["r_iops"] = dm["r_iops"] if dm else None
    s["rd_mib_s"] = dm["rd_mib_s"] if dm else None
    s["kib_per_io"] = dm["kib_per_io"] if dm else None
    s["rd_ios"] = dm["rd_ios"] if dm else None
    s["pgmajfault"] = vm.get("pgmajfault")
    s["majflt_per_s"] = vm["pgmajfault"] / w if vm.get("pgmajfault") is not None and w else None
    s["disk_bytes_per_majfault"] = (dm["rd_bytes"] / vm["pgmajfault"]) if dm and vm.get("pgmajfault") else None
    s["readaround_x"] = s["disk_bytes_per_majfault"] / 4096.0 if s["disk_bytes_per_majfault"] else None
    s["offcpu_frac"] = r.get("offcpu_frac")
    sm = (r.get("sampler") or {})
    tf = sm.get("thread_frac") or {}
    s["samples"] = sm.get("samples")
    for k in ("R", "D", "S_futex", "S_read", "S_other"):
        s["thr_" + k] = tf.get(k)
    cf = sm.get("child_frac") or {}
    s["gzip_R"] = cf.get("R") if cf else None
    s["gzip_S_write"] = cf.get("S_write") if cf else None
    pf = r.get("perf") or {}
    s["ipc"] = r.get("ipc")
    s["dtlb_miss_ratio"] = r.get("dtlb_miss_ratio")
    walk = pf.get("dtlb_walk") or pf.get("armv8_pmuv3_0/dtlb_walk/") or None
    inst = pf.get("instructions")
    s["dtlb_walk_pki"] = (walk / inst * 1000.0) if walk and inst else None
    s["futex_calls_per_s"] = (pf["syscalls:sys_enter_futex"] / w) if pf.get("syscalls:sys_enter_futex") is not None and w else None
    s["cs_per_s"] = (pf["context-switches"] / w) if pf.get("context-switches") is not None and w else (
        r["nvcsw"] / r["wall_s"] if r.get("nvcsw") is not None and r.get("wall_s") else None)
    return s


def main():
    d = sys.argv[1]
    runs = []
    with open(os.path.join(d, "runs.jsonl")) as fh:
        for line in fh:
            if line.strip():
                runs.append(json.loads(line))
    inputs = json.load(open(os.path.join(d, "inputs.json")))
    man = json.load(open(os.path.join(d, "manifest.json"))) if os.path.exists(os.path.join(d, "manifest.json")) else {}
    # Warm validity, keyed on what the page cache actually held. Every cold rung (run or profile)
    # drops the cache, so a warm rung measures its own input's cached table pages only if the
    # rung executed just before it (a profile rung included) read the same file set: the same
    # input and the same database copy (the NVMe file for load/mmap/madv, the tmpfs for ram).
    # ram is exempt: drop_caches does not touch tmpfs. Even after a rung on the same file set, a
    # warm rung is physically cold when the cache could not keep that rung's data:
    #   - the preceding rung (cold or warm) read more from disk than 80% of RAM (disk read bytes,
    #     which include read-around, or major faults x 4 KiB, whichever is larger), or
    #   - the warm rung itself took many major faults: more than 10% of RAM's worth (x 4 KiB), or
    #     more than 10% of the preceding rung's faults, or it timed out.
    mem_b = float((man.get("host") or {}).get("mem_kib") or 0) * 1024
    dbclass = lambda r: "tmpfs" if r["regime"].startswith("ram") else "nvme"
    majf = lambda r: ((r.get("vmstat") or {}).get("pgmajfault") or 0)
    prev = None
    for r in runs:
        if r.get("skipped"):
            continue
        # Only mmap and madv classify through the page cache; load reads the whole table into RAM
        # (warm only shortens its load_s), and ram is on tmpfs.
        if r.get("kind") == "run" and r["state"] == "warm" and r["regime"].split("[")[0] in ("mmap", "madv"):
            why = None
            if prev is None:
                why = "first rung of the run"
            elif prev["input"] != r["input"] or dbclass(prev) != dbclass(r):
                why = "follows %s on %s: the cache held another file set" % (prev.get("tag"), prev["input"])
            else:
                ws = max(float(prev.get("disk_rd_bytes") or 0), majf(prev) * 4096.0)
                own = majf(r)
                if mem_b and ws > 0.8 * mem_b:
                    why = ("physically cold: the preceding rung %s read %.0f GiB from disk, more than 80%% of RAM "
                           "(%.0f GiB), so the cache could not keep it" % (prev.get("tag"), ws / 2**30, mem_b / 2**30))
                elif r.get("timed_out"):
                    why = "physically cold: the warm rung itself timed out"
                elif mem_b and (own * 4096.0 > 0.1 * mem_b or (majf(prev) >= 1000 and own > 0.1 * majf(prev))):
                    why = ("physically cold: the warm rung took %d major faults itself (the preceding rung %d)"
                           % (own, majf(prev)))
            r["warm_invalid"] = why
        prev = r
    excluded = [r for r in runs if r.get("kind") == "run" and not r.get("skipped") and r.get("warm_invalid")]
    done = [r for r in runs if r.get("kind") == "run" and not r.get("skipped") and not r.get("warm_invalid")]
    skipped = [r for r in runs if r.get("skipped")]
    cells = {}
    for r in done:
        # plan `env` / `readahead` lines make their own cells, e.g. load[K2_DB_READ_THREADS=32]
        tags = [t for t in (r.get("env"), r.get("host_tune")) if t]
        if tags:
            r["regime"] = "%s[%s]" % (r["regime"], " ".join(tags))
        cells.setdefault((r["regime"], r["input"], r["state"], r["threads"]), []).append(r)

    rows = []
    sigrows = []
    for key in sorted(cells, key=lambda k: (k[0], k[1], k[2], k[3])):
        rs = cells[key]
        ok = [r for r in rs if r.get("exit") == 0 and not r.get("timed_out")]
        cl = [r.get("classify_s") for r in ok]
        lo, hi = rng(cl)
        inp = inputs.get(key[1]) or {}
        B = inp.get("blocks_8mib")
        T = key[3]
        quant = (math.ceil(B / T) / (B / T)) if B else None
        pairs = inp.get("pairs")
        row = {"regime": key[0], "input": key[1], "state": key[2], "threads": T, "n": len(ok),
               "censored": sum(1 for r in rs if r.get("timed_out")), "failed": sum(1 for r in rs if r.get("exit") not in (0, None) and not r.get("timed_out")),
               "classify_med": med(cl), "classify_min": lo, "classify_max": hi,
               "wall_med": med([r.get("wall_s") for r in ok]), "load_med": med([r.get("load_s") for r in ok]),
               "load_min": rng([r.get("load_s") for r in ok])[0], "load_max": rng([r.get("load_s") for r in ok])[1],
               "pairs": pairs, "pairs_per_s": (pairs / med(cl)) if pairs and med(cl) else None,
               "blocks": B, "quant": quant, "blocks_ok": (B >= 2 * T) if B else None,
               "outputs": sorted(set(r.get("output_sha256") or "-" for r in ok)),
               "timeout_s": max([r.get("wall_s") or 0 for r in rs if r.get("timed_out")] or [0]) or None}
        rows.append(row)
        ss = [sig(r) for r in ok] or [sig(r) for r in rs]
        srow = {"regime": key[0], "input": key[1], "state": key[2], "threads": T, "n": len(ss),
                "blocks_ok": (B >= 2 * T) if B else None, "busy_max": min(T, B) if B else T, "quant": quant}
        for k in ss[0].keys():
            srow[k] = med([s.get(k) for s in ss])
        sigrows.append(srow)

    cols = ["regime", "input", "state", "threads", "n", "censored", "failed", "classify_med", "classify_min",
            "classify_max", "wall_med", "load_med", "load_min", "load_max", "pairs", "pairs_per_s", "blocks", "quant", "blocks_ok"]
    with open(os.path.join(d, "summary.tsv"), "w") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            fh.write("\t".join(f(r[c], 6) if isinstance(r[c], float) else str(r[c]) for c in cols) + "\n")
    scols = list(sigrows[0].keys()) if sigrows else []
    with open(os.path.join(d, "signatures.tsv"), "w") as fh:
        fh.write("\t".join(scols) + "\n")
        for r in sigrows:
            fh.write("\t".join(f(r[c], 6) if isinstance(r[c], float) else str(r[c]) for c in scols) + "\n")

    md = []
    md.append("# make g2: %s\n" % os.path.basename(d.rstrip("/")))
    md.append("| | |\n|---|---|")
    up = man.get("upstream") or {}
    host = man.get("host") or {}
    md.append("| run commit | `%s` (dirty: %s) |" % (man.get("commit"), man.get("tree_dirty")))
    md.append("| summary generated by | `scripts/lib/g2summary.py` at commit `%s` (dirty: %s), %s |" % (GEN_COMMIT, GEN_DIRTY, GEN_AT))
    md.append("| upstream pin | `%s` (`%s`) |" % (up.get("pin"), up.get("describe")))
    md.append("| madvrandom (diagnostic) | %s |" % ("yes: " + str((man.get("madvrandom") or {}).get("install")) if man.get("madvrandom") else "not used"))
    md.append("| host | %s, %s CPUs, %s KiB, kernel %s, THP [%s] defrag [%s] |" % (
        host.get("instance_type") or "local", host.get("ncpu"), host.get("mem_kib"), host.get("kernel"),
        host.get("thp_enabled"), host.get("thp_defrag")))
    if host.get("thp_shmem_enabled") or host.get("numa"):
        md.append("| THP shmem / at end / NUMA | [%s] / [%s] / %s |" % (host.get("thp_shmem_enabled"),
                  host.get("thp_enabled_at_end"), host.get("numa")))
    md.append("| storage | %s |" % (man.get("storage") or "-"))
    md.append("| make run id | %s |" % (man.get("make_run_id") or "-"))
    md.append("| cold | %s (%s) |" % ((man.get("cold") or {}).get("available"), (man.get("cold") or {}).get("method")))
    md.append("| rungs / skipped / failures | %d / %d / %s |" % (len(done), len(skipped), man.get("failures")))
    for n in man.get("notes") or []:
        md.append("| note | %s |" % n)
    md.append("")
    md.append("## Inputs\n")
    md.append("| input | pairs | mate-1 bytes | 8 MiB blocks | max busy threads |\n|---|---|---|---|---|")
    for k, v in sorted(inputs.items()):
        md.append("| %s | %s | %s | %s | %s |" % (k, v["pairs"], v["mate1_bytes"], v["blocks_8mib"], v["blocks_8mib"]))
    md.append("")
    md.append("## Cells (classify_s = upstream's own `processed in`; median [min-max])\n")
    md.append("Warm rungs that were not warm for their own input are excluded from every table below "
              "and listed under *Excluded warm rungs*.\n")
    md.append("| regime | input | state | T | n | classify_s | pairs/s | load_s | wall_s | blocks/T | quant | output sha256 |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        bt = (r["blocks"] / r["threads"]) if r["blocks"] else None
        md.append("| %s | %s | %s | %d | %d%s | %s [%s-%s] | %s | %s [%s-%s] | %s | %s | %s | %s |" % (
            r["regime"], r["input"], r["state"], r["threads"], r["n"],
            (" (+%d censored)" % r["censored"]) if r["censored"] else "",
            f(r["classify_med"]), f(r["classify_min"]), f(r["classify_max"]), f(r["pairs_per_s"], 0),
            f(r["load_med"]), f(r["load_min"]), f(r["load_max"]), f(r["wall_med"]), f(bt, 2), f(r["quant"], 2),
            ",".join(x[:12] for x in r["outputs"])))
    md.append("")
    # output identity across thread counts and regimes, per input
    md.append("## Output identity\n")
    md.append("`--output` must not depend on thread count or regime (all oracle-identical builds; madvrandom changes only page-fault read-around).\n")
    md.append("| input | distinct --output sha256 over all rungs |\n|---|---|")
    byin = {}
    for r in done + excluded:
        if r.get("exit") == 0 and not r.get("timed_out") and r.get("output_sha256"):
            byin.setdefault(r["input"], set()).add(r["output_sha256"])
    for k, v in sorted(byin.items()):
        md.append("| %s | %d %s |" % (k, len(v), "(identical)" if len(v) == 1 else "**DIFFER**"))
    md.append("")

    # ladders
    md.append("## Ladders (speedup and step efficiency)\n")
    md.append("Step efficiency = (throughput gain - 1) / (thread ratio - 1) between consecutive rungs: 1 = linear, "
              "0 = flat, < 0 = slower. A step is *resolved* when the two rungs' classify_s ranges are separated; "
              "rungs with fewer than 2 blocks per thread cannot resolve scaling (8 MiB input blocks).\n")
    lad = {}
    for r in rows:
        lad.setdefault((r["regime"], r["input"], r["state"]), []).append(r)
    for key, rs in sorted(lad.items()):
        rs = sorted(rs, key=lambda x: x["threads"])
        if len(rs) < 2:
            continue
        md.append("**%s / %s / %s**\n" % key)
        md.append("| T | classify_s | pairs/s | speedup vs T=%d | step eff. | resolved | blocks/T >= 2 |" % rs[0]["threads"])
        md.append("|---|---|---|---|---|---|---|")
        base = rs[0]
        knee = None
        for i, r in enumerate(rs):
            sp = (base["classify_med"] / r["classify_med"]) if base["classify_med"] and r["classify_med"] else None
            eff = res = "-"
            if i > 0 and r["classify_med"] and rs[i - 1]["classify_med"]:
                g = rs[i - 1]["classify_med"] / r["classify_med"]
                tr = r["threads"] / rs[i - 1]["threads"]
                e = (g - 1) / (tr - 1)
                eff = f(e, 2)
                sep = (r["classify_max"] < rs[i - 1]["classify_min"]) or (r["classify_min"] > rs[i - 1]["classify_max"])
                if min(r["n"], rs[i - 1]["n"]) < 2:
                    sep = None
                    res = "not resolvable (n=1)"
                else:
                    res = "yes" if sep else "no (ranges overlap)"
                # The best gain block quantization allows: ceil(B/T1) / ceil(B/T2) block rounds.
                B = r["blocks"]
                qi = (math.ceil(B / rs[i - 1]["threads"]) / math.ceil(B / r["threads"])) if B else None
                if knee is None and e < 0.5:
                    knee = (rs[i - 1]["threads"], r["threads"], e, sep, r["blocks_ok"], qi, g)
            md.append("| %d | %s [%s-%s] | %s | %s | %s | %s | %s |" % (
                r["threads"], f(r["classify_med"]), f(r["classify_min"]), f(r["classify_max"]), f(r["pairs_per_s"], 0),
                f(sp, 2), eff, res, r["blocks_ok"]))
        if knee:
            # Coincides with quantization when the quantized ideal itself is small (the step could
            # not gain much) and the observed gain reached at least 90% of it.
            qi, g = knee[5], knee[6]
            qn = ""
            if qi is not None and qi < (knee[1] / knee[0]) * 0.75 and g >= 0.9 * qi:
                qn = ("; **coincides with block quantization**: the quantized ideal gain ceil(B/T1)/ceil(B/T2) is %.2f "
                      "and the observed gain %.2f" % (qi, g))
            elif qi is not None:
                qn = "; quantized ideal gain %.2f, observed %.2f: not explained by quantization" % (qi, g)
            rs_txt = {True: "resolved", False: "NOT resolved: ranges overlap", None: "not resolvable: n=1 at an end of the step"}[knee[3]]
            md.append("\nKnee: first step below 50%% efficiency is T=%d -> %d (efficiency %.2f; %s; blocks/T >= 2 at %d: %s%s).\n" % (
                knee[0], knee[1], knee[2], rs_txt, knee[1], knee[4], qn))
        else:
            md.append("\nNo step below 50% efficiency on this ladder.\n")

    # ---- execution order and drift ----
    # Rungs run in plan order, so a cell measured late in a run differs from an early one by
    # whatever drifted in between. load_s (each load reads the same 1.19 TB) is a drift probe:
    # when it rose by more than 1.5x over the run, a tuned cell that ran entirely after its base
    # cell, with no interleaved base re-run, is confounded with the drift.
    pos = {id(r): i + 1 for i, r in enumerate(done)}
    cellpos = {}
    for r in done:
        cellpos.setdefault((r["regime"], r["input"], r["state"], r["threads"]), []).append(pos[id(r)])
    drift = None
    lr = [r for r in done if r.get("load_s") and r["regime"].startswith("load")]
    probed = len(lr) >= 6
    if probed:
        a, b = med([r["load_s"] for r in lr[:3]]), med([r["load_s"] for r in lr[-3:]])
        if a and b / a > 1.5:
            drift = (a, b, min(r["load_s"] for r in lr), max(r["load_s"] for r in lr))
    confounded = {}
    if drift:
        for key, ps in cellpos.items():
            if "[" not in key[0]:
                continue
            bk = (key[0].split("[")[0],) + key[1:]
            bp = cellpos.get(bk)
            if bp and min(ps) > max(bp):
                confounded[key] = bk
    md.append("## Execution order and drift\n")
    md.append("Rung order is plan order (position 1 = first completed rung). The *Repeated plan lines* column names "
              "cells whose reps came from separate plan lines: their tags all end in -r1, and their rep order is the "
              "execution order shown.\n")
    if drift:
        md.append("**Drift:** load_s of the `load` rungs rose from a median %.1f s (first 3) to %.1f s (last 3), range "
                  "%.1f-%.1f s, over the run. Cells that ran entirely after their base cell, with no interleaved base "
                  "re-run, are **confounded with this drift**: their difference from the base is not attributable to "
                  "the tune, and a slower result shows no gain rather than a measured loss.\n" % drift)
    elif probed:
        md.append("**Drift:** probed on %d `load` rungs; load_s did not rise by more than 1.5x over the run.\n" % len(lr))
    else:
        md.append("**Drift: not probed** (fewer than 6 `load` rungs; the probe is the load time of the default "
                  "load). Cells here may still differ by whatever drifted between them; nothing below rules it out.\n")
    md.append("| cell | positions | median load_s | repeated plan lines | drift |\n|---|---|---|---|---|")
    for key in sorted(cellpos, key=lambda k: min(cellpos[k])):
        rs_ = [r for r in done if (r["regime"], r["input"], r["state"], r["threads"]) == key]
        lines_ = sorted(set(r.get("line") for r in rs_))
        md.append("| %s / %s / %s / T=%d | %s | %s | %s | %s |" % (
            key[0], key[1], key[2], key[3], ",".join(str(x) for x in cellpos[key]),
            f(med([r.get("load_s") for r in rs_])), ("L" + ", L".join(str(x) for x in lines_)) if len(lines_) > 1 else "-",
            ("confounded (ran after %s)" % confounded[key][0]) if key in confounded else ("-" if probed else "not probed")))
    md.append("")

    # gz vs fq
    md.append("## gzip vs plain input (single-stream gzip candidate)\n")
    md.append("| regime | state | T | input | gz classify_s | fq classify_s | gz/fq | separated |\n|---|---|---|---|---|---|---|---|")
    byk = {(r["regime"], r["state"], r["threads"], r["input"]): r for r in rows}
    seen_gz = False
    for (rg, st, T, inp), r in sorted(byk.items()):
        if not inp.endswith("-gz"):
            continue
        q = byk.get((rg, st, T, inp[:-3] + "-fq"))
        if not q or not r["classify_med"] or not q["classify_med"]:
            continue
        seen_gz = True
        sep = (r["classify_min"] > q["classify_max"]) or (r["classify_max"] < q["classify_min"])
        sept = ("not resolvable (n=1)" if min(r["n"], q["n"]) < 2 else ("yes" if sep else "no"))
        md.append("| %s | %s | %d | %s | %s [%s-%s] | %s [%s-%s] | %s | %s |" % (
            rg, st, T, inp[:-3], f(r["classify_med"]), f(r["classify_min"]), f(r["classify_max"]),
            f(q["classify_med"]), f(q["classify_min"]), f(q["classify_max"]), f(r["classify_med"] / q["classify_med"], 3),
            sept))
    if not seen_gz:
        md.append("| (no cell ran both -gz and -fq: the gzip candidate is unresolved here) | | | | | | | |")
    md.append("")

    # signatures
    md.append("## Candidate signatures per cell (medians over reps; classify window only)\n")
    md.append("| regime | input | state | T | aqu-sz (NVMe) | aqu/T | r/s | KiB/IO | MiB/s | majflt | bytes/majflt (x 4 KiB) | off-CPU | R | D | S futex | S read | gzip R | IPC | dTLB miss | dTLB walk/kinst | futex/s |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in sigrows:
        md.append("| %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s (%s) | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            s["regime"], s["input"], s["state"], s["threads"], f(s["aqu_sz"], 1), f(s["aqu_per_thread"], 2),
            f(s["r_iops"], 0), f(s["kib_per_io"], 1), f(s["rd_mib_s"], 0), f(s["pgmajfault"], 0),
            f(s["disk_bytes_per_majfault"], 0), f(s["readaround_x"], 1), f(s["offcpu_frac"], 2),
            f(s["thr_R"], 2), f(s["thr_D"], 2), f(s["thr_S_futex"], 2), f(s["thr_S_read"], 2), f(s["gzip_R"], 2),
            f(s["ipc"], 2), f(s["dtlb_miss_ratio"], 4), f(s["dtlb_walk_pki"], 2), f(s["futex_calls_per_s"], 0)))
    md.append("")

    # IPC per rep, per ladder and T (the resolution of the DRAM/TLB reading)
    ipc_reps = {}
    for r in done:
        if r.get("ipc") is not None:
            ipc_reps.setdefault((r["regime"], r["input"], r["state"]), {}).setdefault(r["threads"], []).append(r["ipc"])
    # page-size contrasts: the same base regime, input, state and T under thp=never and thp=always
    contrast = {}
    for (rg_, st_, T_, in_), r in byk.items():
        if "thp=never" in rg_ and in_.endswith("-fq"):
            q = byk.get((rg_.replace("thp=never", "thp=always"), st_, T_, in_))
            if q and r["classify_med"] and q["classify_med"]:
                csep = (r["classify_min"] > q["classify_max"]) or (r["classify_max"] < q["classify_min"])
                ia = ipc_reps.get((rg_, in_, st_), {}).get(T_, [])
                ib = ipc_reps.get((rg_.replace("thp=never", "thp=always"), in_, st_), {}).get(T_, [])
                isep = bool(ia and ib) and (max(ia) < min(ib) or min(ia) > max(ib))
                pa = cellpos.get((rg_, in_, st_, T_), [])
                pb = cellpos.get((rg_.replace("thp=never", "thp=always"), in_, st_, T_), [])
                if pa and pb and (max(pa) < min(pb) or max(pb) < min(pa)):
                    order = "the two cells ran sequentially, not interleaved (positions %s, then %s)" % (
                        "-".join(str(x) for x in (min(pa), max(pa))) if max(pa) < min(pb) else "-".join(str(x) for x in (min(pb), max(pb))),
                        "-".join(str(x) for x in (min(pb), max(pb))) if max(pa) < min(pb) else "-".join(str(x) for x in (min(pa), max(pa))))
                    if drift:
                        order += ", both after drift onset"
                else:
                    order = "the two cells' rungs were interleaved"
                contrast.setdefault(rg_.split("[")[0], []).append(
                    "%s T=%d: 4 KiB pages (thp=never) %s s [%s-%s] vs THP %s s [%s-%s] (x%s; classify ranges %s); "
                    "per-rep IPC %s vs %s (%s); %s" % (
                        in_, T_, f(r["classify_med"]), f(r["classify_min"]), f(r["classify_max"]),
                        f(q["classify_med"]), f(q["classify_min"]), f(q["classify_max"]),
                        f(r["classify_med"] / q["classify_med"], 2), "separated" if csep else "overlap",
                        ",".join(f(x, 2) for x in sorted(ia)) or "-", ",".join(f(x, 2) for x in sorted(ib)) or "-",
                        "separated: the page-size effect is resolved in IPC" if isep else "not separated", order))

    # mechanical verdicts per regime
    md.append("## Candidates per regime (mechanical reading; see docs/g2.md for the rules)\n")
    md.append("One block of rows per ladder (regime / input / state). Critical sections are read only "
              "on rungs with >= 2 input blocks per thread: with fewer, idle threads wait at the "
              "OpenMP barrier in futex and would look like lock contention.\n")
    md.append("| ladder | candidate | evidence | could the probe resolve it? |\n|---|---|---|---|")
    ladders = sorted(set((s["regime"], s["input"], s["state"]) for s in sigrows))
    for lk in ladders:
        rg = "%s / %s / %s" % lk
        ss = sorted([s for s in sigrows if (s["regime"], s["input"], s["state"]) == lk], key=lambda s: s["threads"])
        if not ss:
            continue
        lo, hi = ss[0], ss[-1]
        # queue depth
        io = [s for s in ss if (s["rd_ios"] or 0) >= 1000]
        if io:
            # A synchronous fault holds one I/O per blocked thread, so the cap shows as aqu-sz equal to
            # the threads in D state (T x the sampler's D fraction). aqu-sz well above that means I/O
            # is issued asynchronously (read-around), so threads do not cap the queue.
            def tdx(s):
                return s["threads"] * (s["thr_D"] or 0)
            ev = "; ".join("T=%d aqu=%s vs T x D=%s (ratio %s)" % (
                s["threads"], f(s["aqu_sz"], 1), f(tdx(s), 1), f((s["aqu_sz"] or 0) / tdx(s), 2) if tdx(s) else "-") for s in io)
            rat = [((s["aqu_sz"] or 0) / tdx(s)) for s in io if tdx(s) >= 1]
            if rat and all(0.8 <= x <= 1.25 for x in rat):
                verdict = "seen: outstanding I/O = blocked threads at every T, so queue depth is capped by the thread count"
            elif rat and all(x > 1.25 for x in rat):
                verdict = "not seen: aqu-sz exceeds the blocked threads (asynchronous read-around I/O), so threads do not cap the queue"
            elif not rat:
                verdict = "unresolved"
            else:
                verdict = "mixed"
            md.append("| %s | sync faults cap NVMe QD (aqu-sz ~ T x D) | %s: %s | %s |" % (
                rg, verdict, ev, "yes (>= 1000 read IOs and T x D >= 1 per rung)" if rat else "no: no rung with T x D >= 1"))
        else:
            md.append("| %s | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |" % rg)
        mj = [s for s in ss if (s["pgmajfault"] or 0) >= 1000]
        if mj:
            ev = "; ".join("T=%d %s x 4 KiB per major fault" % (s["threads"], f(s["readaround_x"], 1)) for s in mj)
            seen = any((s["readaround_x"] or 0) > 2 for s in mj)
            md.append("| %s | read-around amplification | %s: %s | yes (>= 1000 major faults) |" % (rg, "seen" if seen else "not seen", ev))
        else:
            md.append("| %s | read-around amplification | < 1000 major faults | no |" % rg)
        sm = [s for s in ss if (s["samples"] or 0) >= 50 and s.get("blocks_ok") is not False]
        idle = [s["threads"] for s in ss if s.get("blocks_ok") is False]
        if len(sm) < 2 and idle:
            md.append("| %s | critical sections | confounded: fewer than 2 blocks per thread at T=%s | no |" % (
                rg, ",".join(str(t) for t in idle)))
        elif len(sm) >= 2:
            a, b = sm[0], sm[-1]
            ev = "S-futex %s -> %s, off-CPU %s -> %s (T=%d -> %d)" % (f(a["thr_S_futex"], 2), f(b["thr_S_futex"], 2),
                 f(a["offcpu_frac"], 2), f(b["offcpu_frac"], 2), a["threads"], b["threads"])
            grow = (b["thr_S_futex"] or 0) - (a["thr_S_futex"] or 0) > 0.1
            if lk[1].endswith("-gz"):
                v = ("gzip starvation behind seqread: threads wait in futex for the reader, which waits "
                     "on the wrapper's gzip pipes (see the gz/fq table); not lock contention in classify") if grow else "not seen"
            else:
                v = "seen" if grow else "not seen"
                cq = [s_ for s_ in sm if (s_.get("quant") or 1) > 1.1]
                cd = [s_ for s_ in sm if (lk[0], lk[1], lk[2], s_["threads"]) in confounded]
                if grow and (cq or cd):
                    why_ = []
                    if cq:
                        why_.append("end-of-round idle threads (quantization %s at T=%s)" % (
                            ",".join(f(s_["quant"], 2) for s_ in cq), ",".join(str(s_["threads"]) for s_ in cq)))
                    if cd:
                        why_.append("drift (the cell ran after its base cell)")
                    v = "seen but confounded by " + " and ".join(why_)
            md.append("| %s | critical sections | %s: %s | yes (>= 50 samples at >= 2 T) |" % (rg, v, ev))
        else:
            md.append("| %s | critical sections | too few sampler samples | no |" % rg)
        pm = [s for s in ss if s["ipc"] is not None]
        if lk[1].endswith("-gz"):
            md.append("| %s | DRAM/TLB limits | not read: perf stat counts the wrapper's gzip children on gz input; see the -fq ladder | no |" % rg)
        elif pm:
            ipcs = [s["ipc"] for s in pm]
            walks = [s["dtlb_walk_pki"] for s in pm if s["dtlb_walk_pki"] is not None]
            # resolution: the IPC spread across reps of one cell bounds the smallest detectable change
            spreads = [(max(x) - min(x)) for x in ipc_reps.get(lk, {}).values() if len(x) > 1]
            spread = max(spreads or [0])
            ev = "IPC %s..%s, dTLB walks %s..%s per kinst over T=%d..%d" % (
                f(min(ipcs), 2), f(max(ipcs), 2), f(min(walks) if walks else None, 2), f(max(walks) if walks else None, 2),
                pm[0]["threads"], pm[-1]["threads"])
            flat = (max(ipcs) - min(ipcs)) <= max(spread, 0.1)
            ctr = contrast.get(lk[0].split("[")[0], [])
            md.append("| %s | DRAM/TLB limits | %s: %s. Growth with T would show as falling IPC / rising walks; "
                      "whether DRAM/TLB is a lever at all (absolute cost) needs a page-size contrast: %s | "
                      "%s |" % (rg, "flat (no growth with T)" if flat else "changes with T", ev,
                                ("; ".join(ctr)) if ctr else "none in this run, so unresolved",
                                ("yes for growth with T (IPC rep spread %s measured; changes above max(spread, 0.10) resolve)" % f(spread, 2))
                                if spreads else "assumed: every cell has n=1, so the rep spread is not measured; 0.10 is assumed"))
        else:
            md.append("| %s | DRAM/TLB limits | no perf counters | no |" % rg)
        gz = [(k, r) for k, r in byk.items() if k[0] == lk[0] and k[1] == lk[2] and k[3] == lk[1]
              and k[3].endswith("-gz") and (k[0], k[1], k[2], k[3][:-3] + "-fq") in byk]
        if not lk[1].endswith("-gz"):
            pass
        elif gz:
            ev = "; ".join("%s T=%d gz/fq %s" % (k[1], k[2], f(r["classify_med"] / byk[(k[0], k[1], k[2], k[3][:-3] + "-fq")]["classify_med"], 3))
                           for k, r in sorted(gz) if r["classify_med"] and byk[(k[0], k[1], k[2], k[3][:-3] + "-fq")]["classify_med"])
            md.append("| %s | single-stream gzip | %s | yes (gz and fq at the same T) |" % (rg, ev))
        else:
            md.append("| %s | single-stream gzip | no gz/fq pair | no |" % rg)
    md.append("")
    if excluded:
        md.append("## Excluded warm rungs\n")
        md.append("| tag | classify_s | why excluded |\n|---|---|---|")
        for r in excluded:
            md.append("| %s | %s | %s |" % (r["tag"], f(r.get("classify_s")), r["warm_invalid"]))
        md.append("")
    if skipped:
        md.append("## Skipped rungs\n")
        md.append("| tag | why |\n|---|---|")
        for r in skipped:
            md.append("| %s | %s |" % (r["tag"], r["skipped"]))
        md.append("")
    with open(os.path.join(d, "summary.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
