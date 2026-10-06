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
    L.append(f"Repetitions: {man['reps']}; states run: {man['states_run'] or '-'} "
             f"(requested: {man['states_requested']}; cold available: "
             f"{man['cold']['available']}, via {man['cold']['method']}); "
             f"{man['start']} to {man['stop']}.")
    L.append("")
    L.append("Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "
             "\"Loading database information... done.\" on stderr (startup, including upstream's "
             "Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "
             "\"processed in\" figure. tail: that line to exit (report, flushes, teardown). "
             "minflt: minor page faults of the whole process tree. All from `runs.tsv`.")
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
                    if o is not None:
                        L.append(f"- {im} − upstream, median wall: {o - up:+.3f} s "
                                 f"({o:.3f} s vs {up:.3f} s)")
    ladder = [i for i in impls if i not in ("upstream", "ours")]
    if len(ladder) >= 2:
        L.append("")
        L.append("## Attribution (one row per change, Law 5)")
        L.append("")
        L.append("Median wall seconds before → after each change, and the difference; ladder "
                 "order is `LB_LADDER`'s.")
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
            line = f"| {a} → {b} |"
            for inp in inputs:
                for st in states:
                    x, y = med(inp, st, a), med(inp, st, b)
                    line += " - |" if x is None or y is None else f" {x:.3f} → {y:.3f} ({y - x:+.3f}) |"
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
