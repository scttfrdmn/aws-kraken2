#!/usr/bin/env python3
"""TTL estimates for ladder specs at cohorts above 1 (docs/ladder.md, "TTL above c1").

  ladder_ttl.py estimate RUNG COHORT [--vcpus V] [--resolved RES] [--tables DIR]
                         shell lines for scripts/g3/mkspec-ladder.sh: EST_S, TTL (minutes), BASIS,
                         TTLNOTE (the spec's one-line TTL comment); exit 3 if the rung does not resolve
                         at COHORT, 4 if its basis has no measured run, 5 if the TTL is above
                         AK2_MAX_TTL_S (scripts/ak2.env: run.sh refuses it)
  ladder_ttl.py --self-test

The table's ttl_min_c1 is cohort 1's TTL, and a c1 spec keeps it. Above c1 each rung's wall is
estimated from the record's c1 runs of the rung itself or, if it has none, of its nearest measured
relative: its configuration's rung at c1 (ladder_levers.config_row: a rung not run at c1 stands for its
run predecessor, an alias for its winner, an alias_cohorts rung for its target), and failing that its
predecessors in turn. Every c1 run of that rung in the attribution is a basis run (cold ladder runs,
in_attribution yes in a fresh make g3-ladder's runs.tsv).

Per basis run (its lad-sample lines and manifest phases; run phases are the max over its nodes):
  per-invocation part inv = classify - classify-process per sample (upstream's per-sample load and
    setup; 0 where the engine gives no classify-process); it scales with the samples a lane runs;
  classification part proc = classify-process (else classify), per pair; it scales with the pairs
    and with the thread slowdown below;
  upload = the lad-sample upload phase (serial upload modes), per pair, serial on the node;
  fetch-inputs and identity = the run phases, per input byte;
  fixed part F = wall - (the union of the samples' [t_start, t_end] + upload + fetch-inputs +
    identity): boot, setup, staging the table, its load where it is not per sample, push. F < 0
    is clamped to 0, with a note.
The target at COHORT (its resolved PARAMs, on its host of V vCPUs; samples: ranks 1..COHORT of
results/cohort/PRJNA398089/runs.tsv): the samples split over REPLICAS by PLACEMENT, then within a
replica over W lanes by PLACEMENT (W = PROCS on the per-sample path, INFLIGHT on the engine). A lane
runs its samples one after another:
  lane = sum over its samples of (inv + proc per pair x pairs x slowdown),
  slowdown = max(1, e_basis / e_target), e = min(threads, vCPUs / W) the cores a sample has (the
    basis ran one sample, W = 1), and for the engine x max(1, N_basis / N_target) shards;
  replica = its busiest lane + upload per pair x its pairs + (fetch-inputs + identity) per byte x its bytes;
  estimate = F + the busiest replica's. The largest estimate over the basis runs is used.
TTL = max(30 min, 2.5 x estimate), rounded up to 10 min; cost_limit = TTL x the on-demand price
(mkspec-ladder.sh). The model is linear and serial within a lane (no cross-lane contention below
the thread slowdown), so the factor 2.5 is the margin for what it leaves out.
"""
import csv
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ladder_levers as LL  # noqa: E402

ROOT = LL.ROOT
FACTOR = 2.5
FLOOR_MIN = 30
STEP_MIN = 10


def max_ttl_s(root=ROOT):
    """AK2_MAX_TTL_S from scripts/ak2.env (run.sh's limit), else 8 h."""
    try:
        with open(os.path.join(root, "scripts", "ak2.env")) as f:
            for line in f:
                m = re.match(r"\s*AK2_MAX_TTL_S=([0-9]+)", line)
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 28800


def ttl_minutes(est_s):
    """max(30 min, 2.5 x the estimate), rounded up to 10 min."""
    return max(FLOOR_MIN, int(math.ceil(FACTOR * est_s / (60.0 * STEP_MIN) - 1e-9)) * STEP_MIN)


def union_seconds(spans):
    tot, end = 0.0, None
    for a, b in sorted(spans):
        if end is None or a > end:
            tot += b - a
            end = b
        elif b > end:
            tot += b - end
            end = b
    return tot


# ---------------------------------------------------------------- the record

def fresh_tables(root=ROOT):
    """A fresh make g3-ladder into a scratch dir: (rows of its runs.tsv, its manifest's runs)."""
    d = tempfile.mkdtemp(prefix="ak2-ttl-")
    try:
        p = subprocess.run([sys.executable, os.path.join(HERE, "ladder_tables.py"), "--results", os.path.join(root, "results"),
                            "--levers", os.path.join(root, "scripts", "g3", "ladder.levers.tsv"),
                            "--resolved", os.path.join(root, "scripts", "g3", "ladder.resolved.tsv"), "--out", d],
                           capture_output=True, text=True)
        if not re.search(r"^ladder_tables: \d+ ladder run\(s\)", p.stdout, re.M):
            raise SystemExit("ladder_ttl: make g3-ladder gave no summary line (exit %d):\n%s" % (p.returncode, (p.stdout + p.stderr)[-1500:]))
        return read_tables(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def read_tables(d):
    with open(os.path.join(d, "runs.tsv")) as f:
        runs = list(csv.DictReader(f, delimiter="\t"))
    with open(os.path.join(d, "manifest.json")) as f:
        man = json.load(f)
    return runs, man.get("runs", [])


def _phases(man):
    out = {}
    for p in man.get("phases") or []:
        out[p["phase"]] = out.get(p["phase"], 0) + (p.get("seconds") or 0)
    return out


def _samples(run_dir):
    out = []
    for dp, _, fs in os.walk(os.path.join(run_dir, "out")):
        for f in sorted(fs):
            if f == "lad-samples.jsonl":
                with open(os.path.join(dp, f)) as fh:
                    out += [json.loads(l) for l in fh if l.strip()]
    return out


def load_run(root, run_dir):
    """{'nodes': [{'phases': {...}}], 'samples': [lad-sample, ...]} of a cohort dir (its members) or a run dir."""
    full = os.path.join(root, run_dir)
    nodes, samples = [], []
    if os.path.isfile(os.path.join(full, "cohort.json")):
        with open(os.path.join(full, "cohort.json")) as f:
            c = json.load(f)
        for m in c.get("members") or []:
            md = os.path.join(os.path.dirname(full), m["run_id"])
            with open(os.path.join(md, "manifest.json")) as f:
                nodes.append({"phases": _phases(json.load(f))})
            samples += _samples(md)
    else:
        with open(os.path.join(full, "manifest.json")) as f:
            nodes.append({"phases": _phases(json.load(f))})
        samples += _samples(full)
    return {"nodes": nodes, "samples": samples}


def c1_record(root=ROOT, tables=None):
    """rung -> [basis run] for every cold c1 ladder run in the attribution: {'id', 'wall_s', 'params',
    'type', 'nodes', 'samples'}."""
    runs, mruns = tables if tables is not None else fresh_tables(root)
    info = {r["run_id"]: r for r in mruns}
    out = {}
    for r in runs:
        if r.get("cohort") != "1" or r.get("in_attribution") != "yes" or r.get("run_kind", "ladder") != "ladder" \
                or r.get("state", "cold") != "cold":
            continue
        try:
            wall = float(r["wall_s"])
        except (TypeError, ValueError):
            continue
        m = info.get(r["run_id"], {})
        d = m.get("dir") or os.path.join("results", "g3", r["run_id"])
        d = os.path.relpath(d, root) if os.path.isabs(d) else d
        rec = load_run(root, d)
        rec.update(id=r["run_id"], wall_s=wall, params={k.upper(): str(v) for k, v in (m.get("params") or {}).items()},
                   type=r.get("type", ""), dir=d)
        out.setdefault(r["rung"], []).append(rec)
    return out


def basis_rung(rows, rung, rec, res1):
    """(the rung whose c1 runs are the basis, how): the rung's own configuration at c1, then its
    predecessors in turn."""
    names = LL.by_name(rows)
    r, seen, steps = names[rung], set(), []
    while r is not None and r["rung"] not in seen:
        seen.add(r["rung"])
        try:
            m = LL.config_row(rows, r, 1, res1)
        except ValueError:
            m = None
        if m is not None and rec.get(m["rung"]):
            # (no apostrophes: the text goes into a single-quoted shell word and the spec's comment)
            how = "its own c1 runs" if m["rung"] == rung and not steps else \
                "the c1 runs of %s (%s)" % (m["rung"], "; ".join(steps + (["%s at c1 has the configuration of %s" % (r["rung"], m["rung"])]
                                                                          if m["rung"] != r["rung"] else [])) or "the nearest measured relative")
            return m["rung"], how
        steps.append("%s has no c1 runs" % (m["rung"] if m is not None else r["rung"]))
        r = LL.pred_of(rows, r)
    return None, "no measured relative at c1 (%s)" % "; ".join(steps)


# ---------------------------------------------------------------- the model

def _num(x, default=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def basis_parts(run, cohort1_bytes=None):
    """The c1 run's parts (see the module doc)."""
    ss = run["samples"]
    if not ss:
        raise ValueError("run %s has no lad-sample lines" % run["id"])
    ph = lambda s, k: _num((s.get("phases") or {}).get(k))   # noqa: E731
    pairs = sum(int(s.get("pairs") or 0) for s in ss)
    nbytes = sum(int(s.get("input_bytes") or 0) for s in ss) or (cohort1_bytes or 0)
    inv = [max(0.0, ph(s, "classify") - ph(s, "classify-process")) if "classify-process" in (s.get("phases") or {}) else 0.0 for s in ss]
    proc = sum(ph(s, "classify-process") if "classify-process" in (s.get("phases") or {}) else ph(s, "classify") for s in ss)
    up = sum(ph(s, "upload") for s in ss)
    span = union_seconds([(_num(s.get("t_start")), _num(s.get("t_end"))) for s in ss])
    fin = max(n["phases"].get("fetch-inputs", 0) for n in run["nodes"])
    idt = max(n["phases"].get("identity", 0) for n in run["nodes"])
    fixed = run["wall_s"] - (span + up + fin + idt)
    return {"pairs": pairs, "bytes": nbytes, "inv": sum(inv) / len(inv), "proc_per_pair": proc / pairs if pairs else 0.0,
            "up_per_pair": up / pairs if pairs else 0.0, "fin_per_byte": fin / nbytes if nbytes else 0.0,
            "idt_per_byte": idt / nbytes if nbytes else 0.0, "fixed": max(0.0, fixed), "fixed_raw": fixed, "span": span,
            "up": up, "fin": fin, "idt": idt}


def _width(params, vcpus):
    if params["CLASSIFIER"] == "ours-engine":
        return 1 if params.get("INFLIGHT", "-") == "-" else LL.vc(params["INFLIGHT"], vcpus)
    return LL.vc(params["PROCS"], vcpus)


def estimate_from(parts, bparams, bvcpus, params, vcpus, samples):
    """The estimated wall (s) of a target with PARAMS on a host of VCPUS over SAMPLES [(acc, pairs,
    bytes)], from one basis run's PARTS (its PARAMS BPARAMS on BVCPUS). Returns a dict."""
    k = int(params["REPLICAS"])
    grp = LL.assign([p for _, p, _ in samples], k, params["PLACEMENT"])
    w = _width(params, vcpus)
    et = max(1e-9, min(LL.vc(params["THREADS"], vcpus), vcpus / float(w)))
    eb = max(1e-9, min(LL.vc(bparams["THREADS"], bvcpus), float(bvcpus)))
    slow = max(1.0, eb / et)
    if params["CLASSIFIER"] == "ours-engine" and bparams.get("CLASSIFIER") == "ours-engine":
        slow *= max(1.0, int(bparams.get("SHARDS", 1)) / float(int(params["SHARDS"])))
    best = None
    for g in range(k):
        mine = [s for s, gi in zip(samples, grp) if gi == g]
        if not mine:
            continue
        lanes = LL.assign([p for _, p, _ in mine], w, params["PLACEMENT"])
        lt = [0.0] * w
        for (_, p, _), li in zip(mine, lanes):
            lt[li] += parts["inv"] + parts["proc_per_pair"] * p * slow
        gp, gb = sum(p for _, p, _ in mine), sum(b for _, _, b in mine)
        rep = max(lt) + parts["up_per_pair"] * gp + (parts["fin_per_byte"] + parts["idt_per_byte"]) * gb
        if best is None or rep > best[0]:
            best = (rep, len(mine), gp, max(lt))
    est = parts["fixed"] + best[0]
    return {"est_s": est, "fixed_s": parts["fixed"], "per_sample_s": best[0], "lane_s": best[3], "samples": best[1],
            "pairs": best[2], "lanes": w, "replicas": k, "slowdown": slow, "fixed_clamped": parts["fixed_raw"] < 0}


def estimate(rows, rung, cohort, params, instance, vcpus=None, res1=None, rec=None, root=ROOT):
    """{'est_s', 'ttl_min', 'basis', 'how', 'runs', 'detail', 'note'} for RUNG resolved at COHORT
    (PARAMS on INSTANCE). Raises LookupError when no relative has c1 runs."""
    rec = c1_record(root) if rec is None else rec
    res1 = {} if res1 is None else res1
    b, how = basis_rung(rows, rung, rec, res1)
    if b is None:
        raise LookupError("%s: %s" % (rung, how))
    vcpus = vcpus or LL.vcpus_of(instance)
    samples = LL.cohort_runs(int(cohort))
    c1 = LL.cohort_runs(1)
    best = None
    for run in rec[b]:
        parts = basis_parts(run, c1[0][2])
        bv = LL.vcpus_of(run["type"]) or vcpus
        d = estimate_from(parts, run["params"], bv, params, vcpus, samples)
        d.update(run=run["id"], parts=parts)
        if best is None or d["est_s"] > best["est_s"]:
            best = d
    ttl = ttl_minutes(best["est_s"])
    runs = ",".join(r["id"] for r in rec[b])
    note = ("TTL = max(30 min, 2.5 x the estimated wall %.0f s), rounded up to 10 min (scripts/lib/ladder_ttl.py), from %s: %s "
            "(the larger estimate: %s): fixed part %.0f s%s + per-sample part %.0f s (the busiest of %d replica(s): %d sample(s), "
            "%.1f M pairs, %d lane(s), thread slowdown %.2f)" % (
                best["est_s"], how, runs, best["run"], best["fixed_s"], " (clamped from a negative)" if best["fixed_clamped"] else "",
                best["per_sample_s"], best["replicas"], best["samples"], best["pairs"] / 1e6, best["lanes"], best["slowdown"]))
    return {"est_s": best["est_s"], "ttl_min": ttl, "basis": b, "how": how, "runs": runs, "detail": best, "note": note}


# ---------------------------------------------------------------- command line

def _estimate_main(a):
    rung, cohort = a[0], a[1]
    vcpus, resd, tables = None, LL.RESOLVED, None
    rest = a[2:]
    while rest:
        if len(rest) < 2:
            raise SystemExit("ladder_ttl: flag %s needs a value" % rest[0])
        f, v, rest = rest[0], rest[1], rest[2:]
        if f == "--vcpus":
            vcpus = int(v)
        elif f == "--resolved":
            resd = v
        elif f == "--tables":
            tables = read_tables(v)
        else:
            raise SystemExit("ladder_ttl: unknown flag %s" % f)
    rows = LL.load()
    try:
        r = LL.resolve(rows, rung, int(cohort), resd)
        res1 = LL.read_resolved(resd, ROOT, rows)
    except (LL.Unresolved, ValueError) as e:
        print("ladder_ttl: refused: %s" % e, file=sys.stderr)
        return 3
    try:
        e = estimate(rows, rung, int(cohort), r["params"], r["instance"], vcpus, res1, c1_record(ROOT, tables))
    except (LookupError, ValueError) as x:
        print("ladder_ttl: refused: %s" % x, file=sys.stderr)
        return 4
    mx = max_ttl_s()
    print("EST_S=%.0f" % e["est_s"])
    print("TTL=%d" % e["ttl_min"])
    print("BASIS='%s'" % e["basis"])
    print("TTLNOTE='%s'" % e["note"].replace("'", ""))
    if e["ttl_min"] * 60 > mx:
        print("ladder_ttl: refused: %s at c%s: TTL %d min is above AK2_MAX_TTL_S = %d s (%d min; scripts/ak2.env), which run.sh refuses: "
              "%s" % (rung, cohort, e["ttl_min"], mx, mx // 60, e["note"]), file=sys.stderr)
        return 5
    return 0


def _self_test():
    fails = []

    def ok(what, cond, got=""):
        print(("ok   " if cond else "FAIL ") + what + ("" if cond else "  [got %r]" % (got,)))
        if not cond:
            fails.append(what)

    # TTL rounding.
    ok("ttl: a short estimate gets the 30 min floor", ttl_minutes(100) == 30, ttl_minutes(100))
    ok("ttl: 1000 s x 2.5 = 41.7 min -> 50", ttl_minutes(1000) == 50, ttl_minutes(1000))
    ok("ttl: 1200 s x 2.5 = 50 min exactly -> 50", ttl_minutes(1200) == 50, ttl_minutes(1200))
    # A synthetic basis run (unit test only: Law 3): wall 1000 s, one sample of 10 M pairs, 1 GB:
    # classify 300 s of which classify-process 100 s (inv 200 s), upload 5 s, fetch-inputs 10 s, identity 0.
    run = {"id": "r1", "wall_s": 1000.0, "type": "x8g.24xlarge",
           "nodes": [{"phases": {"fetch-inputs": 10, "classify": 300}}],
           "samples": [{"pairs": 10_000_000, "input_bytes": 1_000_000_000, "t_start": 100.0, "t_end": 400.0,
                        "phases": {"classify": 300.0, "classify-process": 100.0, "upload": 5.0}}]}
    p = basis_parts(run)
    ok("parts: fixed = 1000 - (300 + 5 + 10) = 685", abs(p["fixed"] - 685) < 1e-6, p)
    ok("parts: inv 200 s per sample, proc 1e-5 s per pair", abs(p["inv"] - 200) < 1e-9 and abs(p["proc_per_pair"] - 1e-5) < 1e-12, p)
    base = dict(CLASSIFIER="upstream", THREADS="vcpus", PROCS="1", REPLICAS="1", SHARDS="1", PLACEMENT="mod", INFLIGHT="-")
    smp = [("a", 10_000_000, 1_000_000_000), ("b", 20_000_000, 2_000_000_000), ("c", 10_000_000, 1_000_000_000)]
    d = estimate_from(p, base, 96, base, 96, smp)
    # one lane: 3 x 200 + 1e-5 x 40e6 = 1000; upload 5e-7 x 40e6 = 20; fetch 1e-8 x 4e9 = 40.
    ok("serial, same threads: 685 + 3 x 200 + 400 + 20 + 40 = 1745", abs(d["est_s"] - 1745) < 1e-6, d)
    # Two lanes (PROCS=vcpus/48 = 2 on 96 vCPUs, THREADS 48): mod puts a and c on lane 0, b on lane 1;
    # e = min(48, 96/2) = 48 against the basis's 96: slowdown 2. Lane 0: 2 x 200 + 2 x 1e-5 x 20e6 = 800;
    # lane 1: 200 + 2 x 1e-5 x 20e6 = 600.
    two = dict(base, THREADS="48", PROCS="vcpus/48")
    d = estimate_from(p, base, 96, two, 96, smp)
    ok("two lanes, half the threads: 685 + 800 + 20 + 40 = 1545, slowdown 2", abs(d["est_s"] - 1545) < 1e-6 and d["slowdown"] == 2 and d["lanes"] == 2, d)
    # Two replicas (K = 2, mod): a, c on node 0 (20 M pairs, 2 GB), b on node 1 (20 M, 2 GB): each node
    # 2 x 200 + 200 = 600 or 200 + 200 = 400; the busiest: 600 + 10 + 20 = 630.
    d = estimate_from(p, base, 96, dict(base, REPLICAS="2"), 96, smp)
    ok("two replicas: 685 + 600 + 10 + 20 = 1315", abs(d["est_s"] - 1315) < 1e-6 and d["replicas"] == 2, d)
    # The engine (no classify-process: inv 0), INFLIGHT 4 on an 8-vCPU host at THREADS 12: e = min(12, 8/4) = 2
    # against an engine basis of THREADS 8 on 8 vCPUs (e = 8): slowdown 4; basis N 32, target N 16: x 2.
    erun = {"id": "e1", "wall_s": 300.0, "type": "x8g.2xlarge", "nodes": [{"phases": {"fetch-inputs": 4, "identity": 26}}, {"phases": {"identity": 11}}],
            "samples": [{"pairs": 10_000_000, "input_bytes": 1_000_000_000, "t_start": 0.0, "t_end": 10.0, "phases": {"classify": 10.0}}]}
    ep = basis_parts(erun)
    ok("engine parts: fixed = 300 - (10 + 0 + 4 + 26) = 260 (run phases: the max over nodes)", abs(ep["fixed"] - 260) < 1e-6 and ep["inv"] == 0, ep)
    eng = dict(base, CLASSIFIER="ours-engine", THREADS="12", PROCS="1", SHARDS="16", INFLIGHT="4", PLACEMENT="lpt")
    d = estimate_from(ep, dict(eng, THREADS="vcpus", SHARDS="32", INFLIGHT="1"), 8, eng, 8, smp)
    # lanes (lpt over 4): b alone, a, c alone; each sample 1e-6 x pairs x 8: b 160 s; fetch+identity 3e-8 x 4e9 = 120.
    ok("engine: slowdown 4 x 2 = 8, busiest lane 160 s: 260 + 160 + 120 = 540", abs(d["est_s"] - 540) < 1e-6 and d["slowdown"] == 8, d)
    # A negative fixed part is clamped (and flagged).
    bad = dict(run, wall_s=200.0)
    ok("a basis run whose parts exceed its wall: fixed clamped to 0", basis_parts(bad)["fixed"] == 0 and basis_parts(bad)["fixed_raw"] < 0)
    # The basis: S4-t12 at c1 is not run there, so its basis is S2a's runs; O4b-if2's is O4a's.
    rows = LL.load()
    rec = {"S2a": [run], "O4a": [erun], "S0-T1": [run]}
    ok("basis: S4-t12 -> S2a (not run at c1: its run predecessor's configuration)", basis_rung(rows, "S4-t12", rec, {})[0] == "S2a",
       basis_rung(rows, "S4-t12", rec, {}))
    ok("basis: O4b-if2 -> O4a", basis_rung(rows, "O4b-if2", rec, {})[0] == "O4a", basis_rung(rows, "O4b-if2", rec, {}))
    ok("basis: S0-T1 -> its own c1 runs", basis_rung(rows, "S0-T1", rec, {}) == ("S0-T1", "its own c1 runs"), basis_rung(rows, "S0-T1", rec, {}))
    ok("basis: none for a rung with no measured relative", basis_rung(rows, "S1", {"S2a": [run]}, {})[0] is None)
    # The committed record (real c1 runs): S0-T1 at c10, 10 serial samples at T = 1, within run.sh's 8 h limit.
    try:
        real = c1_record(ROOT)
    except SystemExit as e:
        real = None
        ok("the committed record's tables run", False, str(e))
    if real is not None and real.get("S0-T1"):
        r0 = LL.resolve(rows, "S0-T1", 10, LL.RESOLVED)
        e = estimate(rows, "S0-T1", 10, r0["params"], r0["instance"], None, LL.read_resolved(LL.RESOLVED, ROOT, rows), real)
        ok("the committed record: S0-T1 at c10 has TTL %d min (estimate %.0f s), within AK2_MAX_TTL_S" % (e["ttl_min"], e["est_s"]),
           e["ttl_min"] * 60 <= max_ttl_s() and e["basis"] == "S0-T1", e)
    print("ladder_ttl: self-test %s" % ("ok" if not fails else "FAILED (%d)" % len(fails)))
    return 1 if fails else 0


def main(a):
    if a and a[0] == "--self-test":
        return _self_test()
    if len(a) >= 3 and a[0] == "estimate":
        return _estimate_main(a[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
