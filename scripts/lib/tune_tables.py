#!/usr/bin/env python3
"""Tables for the G3 tune-selection probe (#41; scripts/g3/probe-tune.body.sh, docs/probes.md),
from the record only (the run dir's pushed out/tune.jsonl):

  tune_tables.py RUN_DIR      -> tables/probe-tune-trials.tsv, probe-tune.tsv,
                                 probe-tune-selection.tsv, probe-tune-drift.tsv
  tune_tables.py --self-test  the selection rule on synthetic cells, and the body's registered
                              SCHED checked for its properties (make test)

The selection rule is the one registered in the spec's header (applied per regime):
  valid trial: load_exit == classify_exit == 0, applied, output_sha256 and report_sha256 == the
  run's modal ones; warm-up trials and every trial of a rep that did not record all 12 of its
  trials are excluded from the cells;
  total_s = precompact_s (0 without the step) + load_s + classify_s; a cell needs >= 3 valid;
  S != none qualifies iff median(none) - median(S) > 2 x max(range(none), range(S)) and
  median classify(S) <= median classify(none) + 2 x max(crange(none), crange(S));
  the qualifying set with the lowest median total wins, else none.
Resolution, per regime: the smallest gain the rule can accept is 2 x range(none) (no set's
threshold is lower). The load ceiling is median load_s(none) - the load floor (object bytes /
the faster network-ceiling rate): an upper bound on what a set could gain on the load side. If
the ceiling is below the resolution, a none verdict is "not evidence". The classify resolution,
2 x crange(none), is printed beside it (the classify side has no ceiling of its own here).
Exits 1 if a table cannot be made, or if the completed trials' outputs or reports are not all
identical across both regimes (a Law 1 defect).
"""
import csv, json, os, re, statistics, sys
from collections import Counter

SETS = ["none", "precompact", "proactive", "defer", "defermadv", "always"]
MIN_N = 3
CELLS_PER_REP = 2 * len(SETS)


def med(v):
    return statistics.median(v) if v else None


def rng(v):
    return (max(v) - min(v)) if v else None


def f(x, p=3):
    return "-" if x is None else f"{x:.{p}f}"


def valid(t, modal, modal_rep=None):
    return (t.get("load_exit") == 0 and t.get("classify_exit") == 0 and t.get("applied") is True
            and t.get("total_s") is not None and t.get("output_sha256") == modal
            and (modal_rep is None or t.get("report_sha256") == modal_rep))


def modal_sha(trials, key="output_sha256"):
    c = Counter(t.get(key) for t in trials if t.get(key) not in (None, "-"))
    return c.most_common(1)[0][0] if c else None


def complete_reps(trials):
    """The reps (> 0) that recorded all their trials: only these count in the cells."""
    n = Counter(t["rep"] for t in trials if not t.get("warmup") and t.get("rep", 0) > 0)
    return {r for r, k in n.items() if k == CELLS_PER_REP}


def schedule_check(sched, warmup=(("none", "a"), ("none", "b"))):
    """sched: one list of (set, regime) per rep. Returns the violated properties (empty = ok):
    every rep runs all 12 cells once; every set's a-before-b order flips from rep to rep; every
    cell's trials follow distinct predecessors, of both regimes; within each regime, every cell
    has the same number of trials that follow a trial of the other regime (so a cross-regime
    carry-over, e.g. a 1.1 TB anonymous free before a tmpfs staging, weighs on every set alike);
    the sets' mean positions differ by at most 1 trial and the cells' by at most 3; no regime
    runs 3 times in a row."""
    bad = []
    cells = {(s, g) for s in SETS for g in "ab"}
    for r, rep in enumerate(sched):
        if sorted(rep) != sorted(cells):
            bad.append(f"rep {r + 1} does not run every cell exactly once")
    if bad:
        return bad
    for s in SETS:
        o = [rep.index((s, "a")) < rep.index((s, "b")) for rep in sched]
        if any(o[i] == o[i + 1] for i in range(len(o) - 1)):
            bad.append(f"{s}: regime order does not flip every rep ({o})")
    seq = list(warmup) + [c for rep in sched for c in rep]
    pos, pred = {}, {}
    for i in range(len(warmup), len(seq)):
        c = seq[i]
        pos.setdefault(c[0], []).append(i)
        pos.setdefault(c, []).append(i)
        pred.setdefault(c, []).append(seq[i - 1])
    for c, p in pred.items():
        if len(set(p)) != len(p):
            bad.append(f"{c}: repeated predecessor {p}")
        if len({x[1] for x in p}) < 2:
            bad.append(f"{c}: predecessors all of regime {p[0][1]}")
    for g in "ab":
        cross = {c: sum(x[1] != g for x in p) for c, p in pred.items() if c[1] == g}
        if len(set(cross.values())) > 1:
            bad.append(f"regime {g}: cross-regime predecessor counts differ across cells {sorted(cross.items())}")
    sm =[statistics.mean(pos[s]) for s in SETS]
    cm = [statistics.mean(pos[c]) for c in cells]
    if max(sm) - min(sm) > 1.0:
        bad.append(f"set mean positions spread {max(sm) - min(sm):.2f} > 1")
    if max(cm) - min(cm) > 3.0:
        bad.append(f"cell mean positions spread {max(cm) - min(cm):.2f} > 3")
    for i in range(2, len(seq)):
        if seq[i][1] == seq[i - 1][1] == seq[i - 2][1]:
            bad.append(f"regime {seq[i][1]} three times in a row at {i - 1}")
    return bad


def body_schedule(path):
    """The SCHED array registered in the probe body."""
    m = re.search(r"^SCHED=\(\n(.*?)\n\)", open(path).read(), re.S | re.M)
    if not m:
        raise SystemExit(f"tune_tables: no SCHED in {path}")
    return [[tuple(c.split(":")) for c in line.strip().strip('"').split()] for line in m.group(1).splitlines()]


def select(trials, floor_s=None):
    """trials: one regime's trial dicts (already marked valid in t["valid"]). Returns (cells, sel)."""
    cells = {}
    for t in trials:
        c = cells.setdefault(t["set"], {"tot": [], "load": [], "cls": [], "pre": [], "n_all": 0})
        c["n_all"] += 1
        if t["valid"]:
            c["tot"].append(t["total_s"]); c["load"].append(t["load_s"]); c["cls"].append(t["classify_s"])
            c["pre"].append(t.get("precompact_s") or 0.0)
    none = cells.get("none")
    sel = {"chosen": "none", "reason": "", "resolution_s": None, "ceiling_s": None, "evidence": "-"}
    if not none or len(none["tot"]) < MIN_N:
        sel["reason"] = f"none has {len(none['tot']) if none else 0} valid trials (< {MIN_N}): no selection possible"
        sel["chosen"] = "undetermined"
        return cells, sel
    mn, rn, cmn, crn = med(none["tot"]), rng(none["tot"]), med(none["cls"]), rng(none["cls"])
    sel["resolution_s"] = 2 * rn
    sel["resolution_pct"] = 100 * 2 * rn / mn if mn else None
    sel["classify_resolution_s"] = 2 * crn
    if floor_s is not None:
        sel["ceiling_s"] = med(none["load"]) - floor_s
    for s, c in cells.items():
        c["median"] = med(c["tot"]); c["range"] = rng(c["tot"])
        if s == "none" or len(c["tot"]) < MIN_N:
            c["qualifies"] = "-" if s == "none" else f"no (n={len(c['tot'])})"
            continue
        c["gain"] = mn - c["median"]
        c["threshold"] = 2 * max(rn, c["range"])
        c["cls_limit"] = cmn + 2 * max(crn, rng(c["cls"]))
        ok_gain = c["gain"] > c["threshold"]
        ok_cls = med(c["cls"]) <= c["cls_limit"]
        c["qualifies"] = "yes" if ok_gain and ok_cls else ("no (classify regression)" if ok_gain else "no (gain within 2x range)")
    q = [s for s, c in cells.items() if c.get("qualifies") == "yes"]
    if q:
        best = min(q, key=lambda s: (cells[s]["median"], SETS.index(s) if s in SETS else 99))
        sel["chosen"] = best
        sel["reason"] = (f"{best}: median {cells[best]['median']:.3f} s vs none {mn:.3f} s, gain "
                         f"{cells[best]['gain']:.3f} s > threshold {cells[best]['threshold']:.3f} s")
        sel["evidence"] = "yes"
    else:
        sel["reason"] = f"no set's gain exceeds its threshold (resolution {2 * rn:.3f} s)"
        if sel["ceiling_s"] is not None and sel["ceiling_s"] < sel["resolution_s"]:
            sel["evidence"] = "no: the load ceiling is below the resolution, so this null is not evidence"
        elif sel["ceiling_s"] is not None:
            sel["evidence"] = "yes: the probe could resolve a load-side gain up to the ceiling"
        else:
            sel["evidence"] = "unknown: no network ceiling recorded"
    return cells, sel


def write(path, head, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(head)
        w.writerows(rows)
    print(f"tune_tables: {path} ({len(rows)} rows)")


def tables(d):
    L = [json.loads(x) for x in open(os.path.join(d, "out", "tune.jsonl")) if x.strip()]
    trials = [x for x in L if x.get("kind") == "trial"]
    nets = [x for x in L if x.get("kind") == "net" and x.get("exit") == 0 and x.get("load_floor_s")]
    if not trials:
        sys.exit("tune_tables: no trial lines")
    modal, modal_rep = modal_sha(trials), modal_sha(trials, "report_sha256")
    reps = complete_reps(trials)
    for t in trials:
        t["valid"] = valid(t, modal, modal_rep)
        t["counted"] = t["valid"] and not t.get("warmup") and t.get("rep") in reps
    partial = sorted({t["rep"] for t in trials if not t.get("warmup") and t.get("rep") not in reps})
    floor = min(x["load_floor_s"] for x in nets) if nets else None  # the faster read: the larger (upper-bound) ceiling
    td = os.path.join(d, "tables")
    vd = lambda t, k: (t.get("vmstat_delta") or {}).get(k)
    # The trial that ran just before each one (by position; the first has none): carry-over is
    # read from prev_regime and prev_set.
    bypos = {t["pos"]: t for t in trials}
    for t in trials:
        p = bypos.get(t["pos"] - 1)
        t["prev_regime"], t["prev_set"] = (p["regime"], p["set"]) if p else ("-", "-")
    write(os.path.join(td, "probe-tune-trials.tsv"),
          ["pos", "rep", "warmup", "regime", "set", "prev_regime", "prev_set", "valid", "counted", "applied", "precompact_s", "load_s", "classify_s", "total_s", "wall_s",
           "teardown_s", "pre_free_huge_frac", "compact_stall", "compact_success", "compact_fail", "thp_fault_alloc",
           "thp_fault_fallback", "thp_file_alloc", "thp_file_fallback", "shmem_huge_kb_after_load", "anon_huge_kb_peak",
           "shmem_pmd_mapped_kb_peak", "output_sha256"],
          [[t["pos"], t["rep"], "yes" if t.get("warmup") else "no", t["regime"], t["set"], t["prev_regime"], t["prev_set"],
            "yes" if t["valid"] else "no",
            "yes" if t["counted"] else "no", t.get("applied"),
            f(t.get("precompact_s")), f(t.get("load_s")), f(t.get("classify_s")), f(t.get("total_s")), f(t.get("wall_s")),
            f(t.get("teardown_s")), f(t.get("pre_free_huge_frac"), 4), vd(t, "compact_stall"), vd(t, "compact_success"),
            vd(t, "compact_fail"), vd(t, "thp_fault_alloc"), vd(t, "thp_fault_fallback"), vd(t, "thp_file_alloc"),
            vd(t, "thp_file_fallback"), t.get("shmem_huge_kb_after_load"), t.get("anon_huge_kb_peak"),
            t.get("shmem_pmd_mapped_kb_peak"), (t.get("output_sha256") or "-")[:16]] for t in sorted(trials, key=lambda t: t["pos"])])
    cell_rows, sel_rows, drift = [], [], []
    for reg in ("a", "b"):
        R = [dict(t, valid=t["counted"]) for t in trials if t["regime"] == reg and not t.get("warmup")]
        if not R:
            continue
        cells, sel = select(R, floor)
        for s in sorted(cells, key=lambda s: SETS.index(s) if s in SETS else 99):
            c = cells[s]
            ms = [t for t in R if t["set"] == s and t["valid"]]
            stall = med([vd(t, "compact_stall") for t in ms if vd(t, "compact_stall") is not None])
            fb = med([(vd(t, "thp_fault_fallback") or 0) + (vd(t, "thp_file_fallback") or 0) for t in ms])
            cell_rows.append([reg, s, len(c["tot"]), c["n_all"], f(med(c["tot"])), f(min(c["tot"]) if c["tot"] else None),
                              f(max(c["tot"]) if c["tot"] else None), f(rng(c["tot"])), f(med(c["load"])), f(rng(c["load"])),
                              f(med(c["cls"])), f(rng(c["cls"])), f(med(c["pre"])), f(c.get("gain")), f(c.get("threshold")),
                              c.get("qualifies", "-"), f(stall, 0), f(fb, 0)])
        sel_rows.append([reg, sel["chosen"], f(sel["resolution_s"]), f(sel.get("resolution_pct"), 2), f(sel.get("classify_resolution_s")), f(floor),
                         f(sel["ceiling_s"]), sel["evidence"], sel["reason"]])
        for t in sorted(R, key=lambda t: t["pos"]):
            drift.append([reg, t["pos"], t["set"], f(t.get("pre_free_huge_frac"), 4), f(t.get("load_s")), f(t.get("classify_s")),
                          vd(t, "compact_stall"), "yes" if t["valid"] else "no"])
    write(os.path.join(td, "probe-tune.tsv"),
          ["regime", "set", "n", "n_trials", "total_s", "min_s", "max_s", "range_s", "load_s", "load_range_s", "classify_s",
           "classify_range_s", "precompact_s", "gain_s", "threshold_s", "qualifies", "compact_stall", "thp_fallbacks"], cell_rows)
    write(os.path.join(td, "probe-tune-selection.tsv"),
          ["regime", "chosen", "resolution_s", "resolution_pct", "classify_resolution_s", "load_floor_s", "load_ceiling_s", "evidence", "reason"], sel_rows)
    write(os.path.join(td, "probe-tune-drift.tsv"),
          ["regime", "pos", "set", "pre_free_huge_frac", "load_s", "classify_s", "compact_stall", "valid"], drift)
    done = [t for t in trials if t.get("load_exit") == 0 and t.get("classify_exit") == 0]
    shas = {t.get("output_sha256") for t in done}
    rshas = {t.get("report_sha256") for t in done}
    if partial:
        print(f"tune_tables: reps {partial} did not record all {CELLS_PER_REP} trials; their trials are not counted")
    for row in sel_rows:
        print("tune_tables: regime %s -> %s (resolution %s s, ceiling %s s; evidence: %s)" % (row[0], row[1], row[2], row[6], row[7]))
    if len(shas) > 1 or len(rshas) > 1:
        print(f"tune_tables: DEFECT: completed trials wrote {len(shas)} different outputs and {len(rshas)} different reports (Law 1)",
              file=sys.stderr)
        return 1
    und = [r for r in ("a", "b") if r not in {row[0] for row in sel_rows if row[1] != "undetermined"}]
    if und:
        print(f"tune_tables: UNDETERMINED: regime(s) {', '.join(und)} have no selection (complete reps {sorted(reps)}; "
              f"a TTL kill anywhere in rep 3 leaves fewer than {MIN_N} counted trials per cell). S3's set is NOT chosen by this run.",
              file=sys.stderr)
        return 3
    return 0


def self_test():
    def T(reg, s, tot, cls=2.0, ok=True, sha="x"):
        return {"regime": reg, "set": s, "total_s": tot, "load_s": tot - cls, "classify_s": cls, "precompact_s": 0.0,
                "valid": ok, "output_sha256": sha}
    # A clear winner (defer), a set inside the noise (proactive), a faster set with a classify regression (always).
    tr = ([T("b", "none", v) for v in (330, 332, 334)] + [T("b", "defer", v) for v in (300, 301, 303)] +
          [T("b", "proactive", v) for v in (326, 333, 329)] + [T("b", "always", v, cls=3.0) for v in (290, 291, 292)])
    cells, sel = select(tr, floor_s=246.0)
    assert sel["chosen"] == "defer", sel
    assert cells["proactive"]["qualifies"].startswith("no (gain"), cells["proactive"]
    assert cells["always"]["qualifies"] == "no (classify regression)", cells["always"]
    assert abs(sel["resolution_s"] - 8.0) < 1e-9, sel
    # Two qualifying sets: the lower median wins.
    tr2 = tr + [T("b", "precompact", v) for v in (295, 296, 297)]
    assert select(tr2)[1]["chosen"] == "precompact"
    # Gain exactly at the threshold does not qualify (strictly greater).
    tr3 = [T("a", "none", v) for v in (100, 101, 102)] + [T("a", "defer", v) for v in (96, 97, 98)]
    assert select(tr3)[1]["chosen"] == "none"
    # Fewer than 3 valid trials: the set cannot be chosen, however fast.
    tr4 = [T("a", "none", v) for v in (100, 101, 102)] + [T("a", "defer", 50), T("a", "defer", 51), T("a", "defer", 52, ok=False)]
    c4, s4 = select(tr4)
    assert s4["chosen"] == "none" and c4["defer"]["qualifies"] == "no (n=2)", c4["defer"]
    # The resolution check: a null whose ceiling is below the resolution is not evidence.
    tr5 = [T("a", "none", v) for v in (250, 260, 270)] + [T("a", "defer", v) for v in (249, 259, 269)]
    s5 = select(tr5, floor_s=245.0)[1]
    assert s5["chosen"] == "none" and s5["evidence"].startswith("no"), s5
    s6 = select([T("a", "none", v) for v in (300, 301, 302)] + [T("a", "defer", v) for v in (299, 300, 301)], floor_s=246.0)[1]
    assert s6["evidence"].startswith("yes"), s6
    # No valid none cell: undetermined.
    assert select([T("a", "none", 1, ok=False)] * 3)[1]["chosen"] == "undetermined"
    # Validity: a differing output is invalid.
    assert not valid({"load_exit": 0, "classify_exit": 0, "applied": True, "total_s": 1, "output_sha256": "y"}, "x")
    assert modal_sha([{"output_sha256": "x"}, {"output_sha256": "x"}, {"output_sha256": "y"}]) == "x"
    assert not valid({"load_exit": 0, "classify_exit": 0, "applied": True, "total_s": 1, "output_sha256": "x",
                      "report_sha256": "q"}, "x", "r")
    # Only complete reps count (a TTL kill mid-rep cannot favour the sets that ran early in it).
    tk = ([{"rep": r, "warmup": False} for r in (1, 2) for _ in range(CELLS_PER_REP)] + [{"rep": 3}] * 5
          + [{"rep": 0, "warmup": True}] * 2)
    assert complete_reps(tk) == {1, 2}, complete_reps(tk)
    # The schedule registered in the body has its properties, and the checker catches their absence.
    body = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "g3", "probe-tune.body.sh")
    sched = body_schedule(body)
    assert len(sched) == 3, sched
    bad = schedule_check(sched)
    assert not bad, bad
    # The rotated, back-to-back design this replaced (#41 review B1) must fail.
    rot = [[(SETS[(i + r) % 6], g) for i in range(6) for g in (("a", "b") if (r + 1 + i) % 2 else ("b", "a"))]
           for r in range(3)]
    rb = schedule_check(rot)
    assert any("flip" in b for b in rb) and any("predecessor" in b for b in rb), rb
    assert any("spread" in b or "flip" in b for b in schedule_check([sched[0]] * 3)), "a repeated rep must fail"
    # The SCHED at ddbd4a7 (#41 re-review): always on (a) had 1 trial after a (b) trial, the others 2. It must fail.
    old = ["defer:b precompact:a always:a precompact:b none:a defermadv:a defermadv:b none:b proactive:a proactive:b always:b defer:a",
           "always:b proactive:b defer:a always:a defermadv:b precompact:b proactive:a precompact:a none:b defermadv:a none:a defer:b",
           "none:a proactive:a defer:b defermadv:a none:b defermadv:b precompact:a defer:a proactive:b always:a always:b precompact:b"]
    ob = schedule_check([[tuple(c.split(":")) for c in r.split()] for r in old])
    assert any("cross-regime" in b and "'always', 'a'), 1)" in b for b in ob), ob
    # A run whose rep 3 is cut short is undetermined: the post says so loudly and exits 3.
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "out"))
        pos, L = 0, []
        for rep, rows in ((0, [("none", "a"), ("none", "b")]), (1, sched[0]), (2, sched[1]), (3, sched[2][:5])):
            for s, g in rows:
                pos += 1
                L.append({"kind": "trial", "pos": pos, "rep": rep, "warmup": rep == 0, "set": s, "regime": g, "applied": True,
                          "load_exit": 0, "classify_exit": 0, "load_s": 100.0 + pos % 3, "classify_s": 2.0, "precompact_s": None,
                          "total_s": 102.0 + pos % 3, "output_sha256": "x", "report_sha256": "y"})
        with open(os.path.join(d, "out", "tune.jsonl"), "w") as fh:
            fh.write("".join(json.dumps(x) + "\n" for x in L))
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            rc = tables(d)
        assert rc == 3 and "UNDETERMINED" in err.getvalue(), (rc, err.getvalue())
        tr = list(csv.reader(open(os.path.join(d, "tables", "probe-tune-trials.tsv")), delimiter="\t"))
        h = tr[0]
        assert tr[1][h.index("prev_regime")] == "-" and tr[3][h.index("prev_regime")] == "b" and tr[3][h.index("prev_set")] == "none", tr[3]
    print("tune_tables: self-test ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 2:
        sys.exit(tables(sys.argv[1]))
    else:
        sys.exit(__doc__)
