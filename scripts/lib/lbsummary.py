#!/usr/bin/env python3
"""summary.tsv and summary.md for a make loadbench result directory (docs/loadbench.md).

Usage: lbsummary.py RESULT_DIR

Every number is computed from RESULT_DIR/runs.tsv; the labels come from manifest.json.
Medians with the min-max spread over the repetitions; no single multiplier is reported alone
(Law 5): each implementation's numbers, the difference to upstream, and one row per ladder step.
"""
import csv
import json
import os
import statistics
import sys

METRICS = ["wall_s", "load_s", "classify_s", "tail_s", "minflt", "sys_s"]


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    return statistics.median(vals), min(vals), max(vals)


def fmt(s, prec=3):
    if s is None:
        return "-"
    med, lo, hi = s
    if prec == 0:
        return f"{med:.0f} [{lo:.0f}–{hi:.0f}]"
    return f"{med:.{prec}f} [{lo:.{prec}f}–{hi:.{prec}f}]"


def main():
    res = sys.argv[1]
    man = json.load(open(os.path.join(res, "manifest.json")))
    rows = list(csv.DictReader(open(os.path.join(res, "runs.tsv")), delimiter="\t"))
    impls = [i["label"] for i in man["implementations"]]
    inputs = man["inputs"].split()
    states = man["states_run"].split()
    groups = {}
    for r in rows:
        groups.setdefault((r["input"], r["state"], r["impl"]), []).append(r)

    with open(os.path.join(res, "summary.tsv"), "w") as f:
        f.write("input\tstate\timpl\tn\t" + "\t".join(
            f"{m}_median\t{m}_min\t{m}_max" for m in METRICS) + "\n")
        for inp in inputs:
            for st in states:
                for im in impls:
                    g = groups.get((inp, st, im), [])
                    cells = []
                    for m in METRICS:
                        s = stats([num(r[m]) for r in g])
                        cells += ["-"] * 3 if s is None else [f"{x:.6g}" for x in s]
                    f.write(f"{inp}\t{st}\t{im}\t{len(g)}\t" + "\t".join(cells) + "\n")

    def med(inp, st, im, m="wall_s"):
        s = stats([num(r[m]) for r in groups.get((inp, st, im), [])])
        return None if s is None else s[0]

    L = []
    h = man["host"]
    L.append(f"# make loadbench: {man['db']['dir']}, {man['threads']} threads")
    L.append("")
    L.append(f"Commit `{man['commit']}`{' (dirty tree)' if man['dirty'] else ''}; upstream "
             f"`{man['upstream']['pin']}` ({man['upstream']['describe']}). Host: {h['os']} "
             f"{h['arch']} {h['kernel']}, {h['model']}, {h['ncpu']} CPUs, "
             f"{int(h['mem_bytes']) / 2**30:.0f} GiB, page size {h['page_size']}, THP enabled "
             f"`{h['thp_enabled']}`, defrag `{h['thp_defrag']}`. {h['note']}.")
    reps = (f"cold {man['reps_cold']}, warm {man['reps_warm']}" if "reps_cold" in man
            else str(man["reps"]))
    L.append(f"Repetitions: {reps}; threads fixed at {man['threads']} for both implementations; "
             f"states run: {man['states_run'] or '-'} "
             f"(requested: {man['states_requested']}; cold available: "
             f"{man['cold']['available']}, via {man['cold']['method']}); "
             f"{man['start']} to {man['stop']}.")
    if man.get("warmup"):
        w = man["warmup"]
        L.append(f"Warm-up (unrecorded, not in any cell): one cold run of {w.get('impl')} on "
                 f"`{w.get('input')}` before the matrix, wall {w.get('wall_s')} s, load "
                 f"{w.get('load_s')} s.")
    st_ = man.get("db", {}).get("storage") or {}
    if st_:
        ebs = st_.get("ebs") or {}
        desc = ", ".join(f"{k} {v}" for k, v in [("device", st_.get("device")), ("disk model", st_.get("model")),
                                                  ("EBS", json.dumps(ebs) if ebs else None)] if v)
        L.append(f"Database storage: {desc}.")
    hb = next((f["bytes"] for f in man["db"]["files"] if f["file"] == "hash.k2d"), None)
    if hb and "cold" in states:
        rates = []
        for im in impls:
            for inp in inputs:
                s2 = stats([num(r["load_s"]) for r in groups.get((inp, "cold", im), [])])
                if s2:
                    rates.append(hb / s2[0] / 2**20)
        if rates:
            lo, hi = min(rates), max(rates)
            note = (f"Cold load rate (hash.k2d bytes / median cold load s): {lo:.0f}–{hi:.0f} MiB/s "
                    f"over every implementation and input.")
            if hi <= lo * 1.05:
                note += (" They agree within 5%: the cold rungs are capped by the storage, so they "
                         "cannot resolve a difference in the load path itself.")
            L.append(note)
    L.append("")
    L.append("Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "
             "\"Loading database information... done.\" on stderr (startup, including upstream's "
             "Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "
             "\"processed in\" figure. tail: that line to exit (report, flushes, teardown). "
             "minflt: minor page faults of the whole process tree. All from `runs.tsv`.")
    # Noise floor per cell: the largest |difference of medians| over control pairs, consecutive
    # ladder rungs with the same binary and environment (A/A). Without one, the min–max overlap
    # rule stands in, and the summary says so.
    by_label = {i["label"]: i for i in man["implementations"]}
    ladder = [i for i in impls if i not in ("upstream", "ours")]
    controls = [(a, b) for a, b in zip(ladder, ladder[1:])
                if by_label[a]["sha256"] == by_label[b]["sha256"]
                and by_label[a].get("env", "") == by_label[b].get("env", "")]
    floor = {}
    for inp in inputs:
        for st in states:
            ds = []
            for a, b in controls:
                x, y = med(inp, st, a), med(inp, st, b)
                if x is not None and y is not None:
                    ds.append(abs(y - x))
            floor[(inp, st)] = max(ds) if ds else None

    def wstats(inp, st, im):
        return stats([num(r["wall_s"]) for r in groups.get((inp, st, im), [])])

    def noisy(inp, st, x, y):
        f = floor[(inp, st)]
        if f is not None:
            return abs(y[0] - x[0]) <= f
        return x[1] <= y[2] and y[1] <= x[2]

    def verdict(inp, st, im):
        o, u = wstats(inp, st, im), wstats(inp, st, "upstream")
        if o is None or u is None:
            return None
        d = o[0] - u[0]
        nz = noisy(inp, st, u, o)
        if d <= 0:
            if o[2] < u[1] and not nz:
                return d, "≤ upstream (ranges separated)"
            return d, "≤ upstream by median, within noise"
        return d, ("> upstream by median, within noise" if nz else "> upstream")

    L.append("")
    if controls:
        L.append("Noise floor per cell (largest |Δ median wall| over the A/A control pairs "
                 + ", ".join(f"{a} → {b}" for a, b in controls) + "): "
                 + "; ".join(f"{inp} {st} {floor[(inp, st)]:.3f} s" for inp in inputs for st in states
                             if floor[(inp, st)] is not None)
                 + ". A difference at or below it is marked \"within noise\".")
    else:
        L.append("No A/A control pair in this run: \"within noise\" falls back to overlapping "
                 "min–max ranges, which is lax at small n.")
    fin = "final" if "final" in impls else (ladder[-1] if ladder else ("ours" if "ours" in impls else None))
    if fin and "upstream" in impls:
        L.append("")
        L.append(f"## Acceptance: `{fin}` vs upstream, median whole-process wall")
        L.append("")
        L.append("| cell | upstream s | " + fin + " s | Δ s | verdict |")
        L.append("|---|---|---|---|---|")
        for inp in inputs:
            for st in states:
                v = verdict(inp, st, fin)
                if v:
                    L.append(f"| {inp} {st} | {fmt(wstats(inp, st, 'upstream'))} | "
                             f"{fmt(wstats(inp, st, fin))} | {v[0]:+.3f} | {v[1]} |")
    for inp in inputs:
        for st in states:
            L.append("")
            L.append(f"## input `{inp}`, {st}")
            L.append("")
            L.append("| impl | n | wall s | load s | classify s | tail s | minflt | sys s |")
            L.append("|---|---|---|---|---|---|---|---|")
            for im in impls:
                g = groups.get((inp, st, im), [])
                c = [fmt(stats([num(r[m]) for r in g]), 0 if m == "minflt" else 3) for m in METRICS]
                L.append(f"| {im} | {len(g)} | " + " | ".join(c) + " |")
            up = med(inp, st, "upstream")
            if up is not None:
                L.append("")
                for im in impls:
                    if im == "upstream":
                        continue
                    o = med(inp, st, im)
                    v = verdict(inp, st, im)
                    if o is not None and v:
                        L.append(f"- {im} − upstream, median wall: {o - up:+.3f} s "
                                 f"({o:.3f} s vs {up:.3f} s): {v[1]}")
    if len(ladder) >= 2:
        L.append("")
        L.append("## Attribution (one row per change, Law 5)")
        L.append("")
        L.append("Median [min–max] wall seconds before → after each change, and the difference "
                 "of the medians; \"within noise\" where it is at or below the cell's noise floor "
                 "(above), or, without a control pair, where the min–max ranges overlap. "
                 "\"(A/A control)\" marks a pair with the same binary. Ladder order is "
                 "`LB_LADDER`'s.")
        L.append("")
        hdr = "| change |"
        sep = "|---|"
        for inp in inputs:
            for st in states:
                hdr += f" {inp} {st} |"
                sep += "---|"
        L.append(hdr)
        L.append(sep)
        for a, b in zip(ladder, ladder[1:]):
            line = f"| {a} → {b}{' (A/A control)' if (a, b) in controls else ''} |"
            for inp in inputs:
                for st in states:
                    x = stats([num(r["wall_s"]) for r in groups.get((inp, st, a), [])])
                    y = stats([num(r["wall_s"]) for r in groups.get((inp, st, b), [])])
                    if x is None or y is None:
                        line += " - |"
                        continue
                    noise = noisy(inp, st, x, y)
                    line += (f" {x[0]:.3f} [{x[1]:.3f}–{x[2]:.3f}] → {y[0]:.3f} [{y[1]:.3f}–{y[2]:.3f}]"
                             f" ({y[0] - x[0]:+.3f}{', within noise' if noise else ''}) |")
            L.append(line)
    # Sanity: every implementation wrote the same --output for an input (Law 1 is make oracle's).
    L.append("")
    bad = []
    for inp in inputs:
        shas = {r["output_sha256"] for r in rows if r["input"] == inp and r["exit"] == "0"}
        if len(shas) > 1:
            bad.append(inp)
    L.append("Output check: " + ("every run of an input wrote the same --output bytes."
                                 if not bad else f"--output DIFFERS between runs for {', '.join(bad)}."))
    fails = [r for r in rows if r["exit"] != "0"]
    if fails:
        L.append(f"Runs with a non-zero exit: {len(fails)} (see runs.tsv, stderr/).")
    with open(os.path.join(res, "summary.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
