#!/usr/bin/env python3
"""The #25 ladder tables (#52, WP-8; runbook docs/ladder.md, "Ladder tables"). From the record only.

  ladder_tables.py [--results results] [--levers scripts/g3/ladder.levers.tsv] [--out results/g3/ladder]

Inputs: every ladder run dir under results/<gate>/2026* (a single run's manifest.json, or a
cohort dir's cohort.json with its members' manifests) whose params (manifest "params", else
cohort.json "params", else the rank-0 member's) name a rung; each run's lad-sample lines
(out/**/lad-samples.jsonl, pushed; checked against the `lad-sample {json}` lines streamed into
log/run.log); each run's tables/util.tsv (its fleet row); the lever table ladder.levers.tsv;
results/g3/campaign/spend.tsv (for the spend cross-check).

Outputs (in --out): runs.tsv, tidy.tsv, rungs.tsv, deltas.tsv, effcost.tsv, pairs.tsv, law1.tsv,
law1-detail.tsv, s5-nonpreserving.tsv, endpoints.tsv, spend.tsv, summary.md, manifest.json.

Definitions (also in docs/ladder.md):
  - wall_s: end to end, first launch_time -> last terminated_at over the run's nodes.
  - billed_usd: the manifests' cost_usd (summed over a cohort's members; missing if any member's
    is missing: never imputed).
  - lever_phase_s: the rung's lever's own phase (ladder.levers.tsv `phase`): `run:NAME` is the
    manifest phase NAME (seconds summed per node, max over nodes); `sample:NAME` is the sum over
    the run's lad-sample lines of phases.NAME; a bare NAME is run: if the manifest has it, else
    sample:. NAME may be A+B (summed).
  - median and range (max - min) per (arm, rung, cohort) over cold ladder runs; n >= 2 for a range.
  - A delta (rung - predecessor, medians) is resolved only if |delta| > 2 x max(range of rung,
    range of predecessor); otherwise, or with n < 2 on either side, it is unresolvable. An
    unresolvable delta is never a null.
  - Effective cost per resource: billed_usd / U, for U_cpu, U_mem_mean, U_net (baseline, peak,
    and each direction); never combined.
  - Pairs: S vs S*, S vs O*, S* vs O*, per cohort, on the time endpoint (wall_s) and on the cost
    endpoint (billed_usd and each effective cost). Each total sits beside its per-lever
    decomposition, the rung deltas along the predecessor path.
  - Law 1 across arms: per accession, every run's output file set and on-node sha256 against the
    reference (the first stock-arm run). Any mismatch is a DEFECT and the exit status is 1.
Exit status: 0, or 1 if any DEFECT (Law 1 mismatch, a failed sample, a lad-sample contract error).
"""
import argparse
import csv
import datetime as dt
import glob
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONTRACT_V = 1
S5_STATUS = ("n/a", "identical", "differs")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ROLES = ("output", "report")
U_COLS = ["U_cpu", "U_mem_mean", "U_mem_peak", "U_net_baseline", "U_net_peak", "U_net_rx_baseline", "U_net_rx_peak",
          "U_net_tx_baseline", "U_net_tx_peak"]
# effective cost axis -> the U it divides by
EFF = [("eff_cpu_usd", "U_cpu"), ("eff_mem_usd", "U_mem_mean"), ("eff_net_baseline_usd", "U_net_baseline"),
       ("eff_net_peak_usd", "U_net_peak"), ("eff_net_rx_baseline_usd", "U_net_rx_baseline"),
       ("eff_net_rx_peak_usd", "U_net_rx_peak"), ("eff_net_tx_baseline_usd", "U_net_tx_baseline"),
       ("eff_net_tx_peak_usd", "U_net_tx_peak")]
AXES = ["wall_s", "billed_usd", "lever_phase_s"]
PRED_COL = {"wall_s": "pred_wall_s", "billed_usd": "pred_usd", "lever_phase_s": "pred_phase_s"}
# pair axes: (endpoint family, axis)
PAIR_AXES = [("time", "wall_s"), ("cost", "billed_usd")] + [("cost", e) for e, _ in EFF]
ENDPOINT_PRIMARY = {"time": "wall_s", "cost": "billed_usd"}


# ---------------------------------------------------------------- small helpers
def ts(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()


def num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x


def fmt(v, nd=6):
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, int):
        return str(v)
    if v == float("inf"):
        return "inf"
    return f"{v:.{nd}f}"


class Reader:
    """Reads files and remembers each one with its sha256 (for manifest.json)."""

    def __init__(self):
        self.files = {}

    def text(self, path):
        with open(path, "rb") as f:
            b = f.read()
        self.files[os.path.abspath(path)] = (len(b), hashlib.sha256(b).hexdigest())
        return b.decode("utf-8", errors="replace")

    def json(self, path):
        return json.loads(self.text(path))


def norm_params(p):
    """params: lowercase keys, a leading lad_ or ak2_ stripped; cohort and rep as ints."""
    if not isinstance(p, dict):
        return None
    out = {}
    for k, v in p.items():
        k2 = k.lower()
        for pre in ("lad_", "ak2_lad_", "ak2_"):
            if k2.startswith(pre):
                k2 = k2[len(pre):]
                break
        out[k2] = v
    for k in ("cohort", "rep"):
        if k in out:
            try:
                out[k] = int(out[k])
            except (TypeError, ValueError):
                pass
    out.setdefault("rep", 1)
    out.setdefault("run_kind", "ladder")
    out.setdefault("state", "cold")
    out.setdefault("endpoint", "")
    return out if out.get("rung") else None


# ---------------------------------------------------------------- the lever table
ALIASES = {"predecessor": ("predecessor", "pred", "prev"), "lever": ("lever", "key_group", "lever_key", "key-group"),
           "counterpart": ("counterpart", "o_counterpart"), "phase": ("phase", "lever_phase"), "arm": ("arm",),
           "endpoint": ("endpoint",), "pred_wall_s": ("pred_wall_s",), "pred_usd": ("pred_usd",),
           "pred_phase_s": ("pred_phase_s",)}


def load_levers(path, rd):
    """rung -> {arm, predecessor, lever, counterpart, phase, endpoint, pred_*}. Missing file: {}."""
    if not path or not os.path.exists(path):
        return {}
    lines = [ln for ln in rd.text(path).splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if not lines:
        return {}
    head = lines[0].split("\t")
    out = {}
    for ln in lines[1:]:
        f = dict(zip(head, ln.split("\t")))
        r = {"rung": f.get("rung", "").strip()}
        for k, al in ALIASES.items():
            r[k] = next((f[a].strip() for a in al if a in f and f[a] is not None), "")
        if r["predecessor"] in ("-", "none"):
            r["predecessor"] = ""
        if not r["arm"]:
            r["arm"] = r["rung"][:1]
        if r["rung"]:
            out[r["rung"]] = r
    return out


# ---------------------------------------------------------------- one run
def lad_lines(member_dir, rd, notes, label):
    """The lad-sample objects of one node: pushed out/**/lad-samples.jsonl, checked against the
    streamed log lines."""
    pushed, streamed = [], []
    for p in sorted(glob.glob(os.path.join(member_dir, "out", "**", "lad-samples.jsonl"), recursive=True)):
        for i, ln in enumerate(rd.text(p).splitlines()):
            if ln.strip():
                try:
                    pushed.append(json.loads(ln))
                except ValueError:
                    notes.append(f"{label}: {os.path.relpath(p, member_dir)} line {i + 1} is not JSON")
    log = os.path.join(member_dir, "log", "run.log")
    if os.path.exists(log):
        dec = json.JSONDecoder()
        for ln in rd.text(log).splitlines():
            k = ln.find("lad-sample {")
            if k < 0:
                continue
            try:
                streamed.append(dec.raw_decode(ln[k + len("lad-sample "):])[0])
            except ValueError:
                notes.append(f"{label}: a streamed lad-sample line is not JSON (cut off?)")
    key = lambda o: json.dumps(o, sort_keys=True)
    if pushed and streamed and sorted(map(key, pushed)) != sorted(map(key, streamed)):
        notes.append(f"{label}: streamed lad-sample lines ({len(streamed)}) differ from the pushed file ({len(pushed)}); "
                     "the pushed file is used")
    if pushed:
        return pushed
    if streamed:
        notes.append(f"{label}: no pushed lad-samples.jsonl; lines taken from the streamed log")
    return streamed


def phase_sums(man):
    out = {}
    for p in man.get("phases") or []:
        s = num(p.get("seconds"))
        if p.get("phase") and s is not None:
            out[p["phase"]] = out.get(p["phase"], 0.0) + s
    return out


def read_util(d, rd):
    """The fleet row of d/tables/util.tsv, as {U_*: float|None, coverage}; None if absent."""
    p = os.path.join(d, "tables", "util.tsv")
    if not os.path.exists(p):
        return None
    rows = list(csv.DictReader(rd.text(p).splitlines(), delimiter="\t"))
    fl = [r for r in rows if r.get("scope") == "fleet"] or [r for r in rows if r.get("scope") == "node"]
    if not fl:
        return None
    r = fl[0]
    out = {k: num(r.get(k)) for k in U_COLS}
    out["coverage"] = r.get("coverage", "")
    return out


def read_run(d, rd):
    """A ladder run (single or cohort) or None if d is not a ladder run."""
    notes = []
    mp, cp = os.path.join(d, "manifest.json"), os.path.join(d, "cohort.json")
    if os.path.exists(mp):
        man = rd.json(mp)
        params = norm_params(man.get("params"))
        if not params:
            return None
        members = [(man.get("run_id") or os.path.basename(d), d, man)]
        kind, commit, gate = "single", man.get("commit"), man.get("gate")
    elif os.path.exists(cp):
        coh = rd.json(cp)
        members = []
        for m in coh.get("members", []):
            rid = m.get("run_id")
            md = os.path.join(os.path.dirname(d), rid) if rid else None
            if md and os.path.exists(os.path.join(md, "manifest.json")):
                members.append((rid, md, rd.json(os.path.join(md, "manifest.json"))))
            else:
                notes.append(f"member rank {m.get('rank')}: no manifest")
        params = norm_params(coh.get("params")) or (norm_params(members[0][2].get("params")) if members else None)
        if not params:
            return None
        kind, commit, gate = "cohort", coh.get("commit"), coh.get("gate")
    else:
        return None
    run = {"run_id": os.path.basename(os.path.normpath(d)), "dir": d, "kind": kind, "gate": gate, "commit": commit,
           "params": params, "notes": notes, "nodes": len(members)}
    m0 = members[0][2] if members else {}
    inst = m0.get("instance") or {}
    run.update(type=inst.get("type"), az=inst.get("az"), region=m0.get("region"),
               price=m0.get("truffle_price_usd_per_hour"))
    launches = [ts((m.get("instance") or {}).get("launch_time") or m.get("start")) for _, _, m in members]
    terms = [ts((m.get("instance") or {}).get("terminated_at") or m.get("stop")) for _, _, m in members]
    if members and None not in launches and None not in terms:
        run["wall_s"] = max(terms) - min(launches)
        run["start"] = min(launches)
    else:
        run["wall_s"] = None
        run["start"] = min([x for x in launches if x is not None], default=None)
        notes.append("no launch_time/terminated_at on every node: wall missing")
    costs = [num(m.get("cost_usd")) for _, _, m in members]
    if members and None not in costs:
        run["billed_usd"] = sum(costs)
    else:
        run["billed_usd"] = None
        notes.append("cost_usd missing on a node: billed missing (not imputed)")
    ph = {}
    for _, _, m in members:
        for k, v in phase_sums(m).items():
            ph[k] = max(ph.get(k, v), v)
    run["phases_run"] = ph
    samples = []
    for rid, md, _ in members:
        for o in lad_lines(md, rd, notes, rid):
            o = dict(o)
            o["_node"] = rid
            samples.append(o)
    run["samples"] = samples
    u = read_util(d, rd)
    run["util"] = u
    run["util_coverage"] = "missing (no tables/util.tsv fleet row)" if u is None else (u.get("coverage") or "full")
    run["eff"] = {}
    for e, uk in EFF:
        uv = None if u is None else u.get(uk)
        b = run["billed_usd"]
        run["eff"][e] = None if uv is None or b is None else (float("inf") if uv == 0 else b / uv)
    run["s5_nonpreserving"] = sorted({str(s.get("accession")) for s in samples
                                      if isinstance(s.get("s5"), dict) and s["s5"].get("status") == "differs"})
    return run


def discover(results, rd):
    runs = []
    for d in sorted(glob.glob(os.path.join(results, "*", "2026*"))):
        if not os.path.isdir(d) or re.search(r"-n\d+-r\d+$", os.path.basename(d)):
            continue  # cohort members are read through their cohort
        sub = Reader()  # only a ladder run's files are inputs
        r = read_run(d, sub)
        if r:
            rd.files.update(sub.files)
            runs.append(r)
    return runs


# ---------------------------------------------------------------- contract
def contract_errors(run):
    """lad-sample contract (docs/ladder.md) for every line of a run: a list of strings."""
    errs = []
    p = run["params"]
    for s in run["samples"]:
        acc = s.get("accession", "?")
        where = f"{run['run_id']} {s.get('_node')} {acc}"
        for k in ("v", "arm", "rung", "cohort", "accession", "pairs", "rc", "phases", "outputs", "s5"):
            if k not in s:
                errs.append(f"{where}: missing {k}")
        if s.get("v") not in (None, CONTRACT_V) and "v" in s:
            errs.append(f"{where}: v {s.get('v')} != {CONTRACT_V}")
        for k in ("arm", "rung", "cohort"):
            if k in s and str(s[k]) != str(p.get(k)):
                errs.append(f"{where}: {k} {s[k]!r} != the run's params {p.get(k)!r}")
        if "pairs" in s and not (isinstance(s["pairs"], int) and s["pairs"] >= 0):
            errs.append(f"{where}: pairs is not a non-negative integer")
        if "phases" in s and not (isinstance(s["phases"], dict) and all(num(v) is not None for v in s["phases"].values())):
            errs.append(f"{where}: phases is not an object of seconds")
        outs = s.get("outputs")
        if "outputs" in s:
            if not isinstance(outs, dict):
                errs.append(f"{where}: outputs is not an object")
            else:
                for role in REQUIRED_ROLES:
                    if role not in outs:
                        errs.append(f"{where}: outputs has no {role}")
                for role, o in outs.items():
                    if not isinstance(o, dict) or not HEX64.match(str(o.get("sha256", ""))) or not isinstance(o.get("bytes"), int):
                        errs.append(f"{where}: outputs.{role} needs bytes (int) and sha256 (64 hex)")
        s5 = s.get("s5")
        if "s5" in s and not (isinstance(s5, dict) and s5.get("status") in S5_STATUS):
            errs.append(f"{where}: s5.status must be one of {', '.join(S5_STATUS)}")
    return errs


# ---------------------------------------------------------------- axes, stats, deltas
def phase_value(run, spec):
    if not spec:
        return None
    scope, name = (spec.split(":", 1) if ":" in spec else ("", spec))
    total = 0.0
    for part in name.split("+"):
        if scope == "run" or (scope == "" and part in run["phases_run"]):
            v = run["phases_run"].get(part)
        else:
            vals = [num(s["phases"][part]) for s in run["samples"] if isinstance(s.get("phases"), dict) and part in s["phases"]]
            v = sum(vals) if vals else None
        if v is None:
            return None
        total += v
    return total


def axis_value(run, axis, levers, rung_for_phase):
    if axis == "wall_s":
        return run["wall_s"]
    if axis == "billed_usd":
        return run["billed_usd"]
    if axis == "lever_phase_s":
        return phase_value(run, (levers.get(rung_for_phase) or {}).get("phase"))
    if axis in run["eff"]:
        return run["eff"][axis]
    if run["util"] is not None and axis in U_COLS:
        return run["util"].get(axis)
    return None


def stats(vals):
    v = [x for x in vals if x is not None]
    if not v:
        return {"n": 0, "median": None, "min": None, "max": None, "range": None}
    return {"n": len(v), "median": statistics.median(v), "min": min(v), "max": max(v),
            "range": (max(v) - min(v)) if len(v) >= 2 else None}


def delta(a, b, predicted=None):
    """a: the rung's stats, b: the predecessor's (or target, source). The resolution rule."""
    d = {"delta": None, "status": "", "measured_spread": None, "threshold": None, "predicted": predicted,
         "predicted_resolvable": ""}
    if not a["n"] or not b["n"]:
        d["status"] = "missing: " + ", ".join(w for w, s in (("rung", a), ("predecessor", b)) if not s["n"]) + " has no runs"
        return d
    d["delta"] = a["median"] - b["median"]
    if a["n"] < 2 or b["n"] < 2:
        d["status"] = f"unresolvable: n < 2 (n {a['n']} vs {b['n']}), no spread"
        return d
    d["measured_spread"] = max(a["range"], b["range"])
    d["threshold"] = 2 * d["measured_spread"]
    d["status"] = "resolved" if abs(d["delta"]) > d["threshold"] else "unresolvable: |delta| <= 2 x spread"
    if predicted is not None:
        d["predicted_resolvable"] = "yes" if abs(predicted) > d["threshold"] else "no"
    return d


# ---------------------------------------------------------------- the tables
def ladder_runs(runs):
    """Cold ladder runs that enter the attribution, and the excluded ones with their reason."""
    keep, excl = [], []
    for r in runs:
        p = r["params"]
        if p["run_kind"] != "ladder":
            continue
        if p["state"] != "cold":
            excl.append((r, f"state {p['state']}: ladder runs are cold"))
        elif r["s5_nonpreserving"]:
            excl.append((r, f"S5 not output-preserving on {len(r['s5_nonpreserving'])} sample(s): "
                            f"{', '.join(r['s5_nonpreserving'])}"))
        else:
            keep.append(r)
    return keep, excl


def group_runs(runs):
    """(rung, cohort) -> the runs."""
    g = {}
    for r in runs:
        g.setdefault((r["params"]["rung"], r["params"]["cohort"]), []).append(r)
    return g


def stats_for(groups, rung, cohort, axis, levers, phase_rung):
    rs = groups.get((rung, cohort), [])
    return stats([axis_value(r, axis, levers, phase_rung) for r in rs])


def chain(levers, target):
    out, seen, r = [], set(), target
    while r and r not in seen:
        seen.add(r)
        out.append(r)
        r = (levers.get(r) or {}).get("predecessor", "")
    return out


def endpoints(levers, groups, arm, fam, cohort):
    """The arm's endpoint rung for family fam (time|cost) at cohort, and its basis."""
    tag = f"{arm}*-{fam}"
    decl = [r for r, x in levers.items() if x["arm"] == arm and tag in [t.strip() for t in re.split(r"[;,]", x.get("endpoint", ""))]]
    if decl:
        return decl[0], "declared in ladder.levers.tsv"
    axis = ENDPOINT_PRIMARY[fam]
    cand = []
    for (rung, c), _ in groups.items():
        if c != cohort or (levers.get(rung) or {}).get("arm", rung[:1]) != arm:
            continue
        s = stats_for(groups, rung, c, axis, levers, rung)
        if s["n"]:
            cand.append((s["median"], rung))
    if not cand:
        return None, "no runs"
    return min(cand)[1], f"argmin of the measured rung medians of {axis} (selected from the record)"


def build(runs, levers, campaign_spend=None):
    T = {}
    defects, notes = [], []
    # contract
    for r in runs:
        for e in contract_errors(r):
            defects.append(("contract", e))
        for s in r["samples"]:
            if s.get("rc") not in (0, None) and "rc" in s:
                defects.append(("sample failed", f"{r['run_id']} {s.get('accession')}: rc {s.get('rc')}"))
        if r["params"]["rung"] not in levers:
            notes.append(f"{r['run_id']}: rung {r['params']['rung']} is not in ladder.levers.tsv")
    keep, excl = ladder_runs(runs)
    groups = group_runs(keep)

    # 1. runs.tsv and tidy.tsv
    rh = ["run_id", "gate", "kind", "arm", "rung", "cohort", "rep", "run_kind", "endpoint", "state", "type", "nodes", "az",
          "commit", "price_usd_per_h", "wall_s", "billed_usd", "lever_phase", "lever_phase_s", "samples", "pairs"] + U_COLS + \
         [e for e, _ in EFF] + ["util_coverage", "s5_nonpreserving", "in_attribution", "notes"]
    exr = {id(r): why for r, why in excl}
    rows, tidy = [], []
    for r in runs:
        p = r["params"]
        u = r["util"] or {}
        lp = (levers.get(p["rung"]) or {}).get("phase", "")
        pairs = sum(s.get("pairs") or 0 for s in r["samples"] if isinstance(s.get("pairs"), int))
        inattr = "yes" if (p["run_kind"] == "ladder" and id(r) not in exr) else ("no: " + exr[id(r)] if id(r) in exr
                                                                                   else "no: endpoint decomposition run")
        row = [r["run_id"], r["gate"], r["kind"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"],
               p["endpoint"], p["state"], r["type"], r["nodes"], r["az"], r["commit"], fmt(num(r["price"]), 4),
               fmt(r["wall_s"], 1), fmt(r["billed_usd"]), lp, fmt(phase_value(r, lp), 3), len(r["samples"]), pairs] + \
              [fmt(u.get(k)) for k in U_COLS] + [fmt(r["eff"][e]) for e, _ in EFF] + \
              [r["util_coverage"], ",".join(r["s5_nonpreserving"]), inattr, "; ".join(r["notes"])]
        rows.append(row)
        base = [r["run_id"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"], p["state"]]
        for k, v in (("wall_s", fmt(r["wall_s"], 1)), ("billed_usd", fmt(r["billed_usd"]))):
            tidy.append(base + ["", "", "", k, v])
        for k in U_COLS:
            tidy.append(base + ["", "", "", k, fmt(u.get(k)) if r["util"] else "missing"])
        for e, _ in EFF:
            tidy.append(base + ["", "", "", e, fmt(r["eff"][e]) if r["util"] else "missing"])
        for k, v in sorted(r["phases_run"].items()):
            tidy.append(base + ["", "", "", f"phase.{k}", fmt(v, 3)])
        for s in r["samples"]:
            sb = base + [s.get("_node", ""), s.get("accession", ""), s.get("idx", "")]
            tidy.append(sb + ["pairs", s.get("pairs", "")])
            tidy.append(sb + ["rc", s.get("rc", "")])
            for k, v in sorted((s.get("phases") or {}).items()):
                tidy.append(sb + [f"phase.{k}", v])
            for role, o in sorted((s.get("outputs") or {}).items()):
                if isinstance(o, dict):
                    tidy.append(sb + [f"output.{role}.bytes", o.get("bytes", "")])
                    tidy.append(sb + [f"output.{role}.sha256", o.get("sha256", "")])
            s5 = s.get("s5") if isinstance(s.get("s5"), dict) else {}
            tidy.append(sb + ["s5.status", s5.get("status", "")])
    T["runs.tsv"] = (rh, rows)
    T["tidy.tsv"] = (["run_id", "arm", "rung", "cohort", "rep", "run_kind", "state", "node", "accession", "idx", "metric",
                      "value"], tidy)

    # 2. rungs.tsv (and 4. effcost.tsv)
    sh = ["arm", "rung", "cohort", "axis", "lever_phase", "n", "median", "min", "max", "range"]
    srows, erows = [], []
    for (rung, cohort) in sorted(groups):
        arm = (levers.get(rung) or {}).get("arm", rung[:1])
        for ax in AXES:
            s = stats_for(groups, rung, cohort, ax, levers, rung)
            srows.append([arm, rung, cohort, ax, (levers.get(rung) or {}).get("phase", "") if ax == "lever_phase_s" else "",
                          s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2"])
        for ax in U_COLS + [e for e, _ in EFF]:
            s = stats_for(groups, rung, cohort, ax, levers, rung)
            missing = sum(1 for r in groups[(rung, cohort)] if r["util"] is None)
            erows.append([arm, rung, cohort, ax, s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2",
                          f"util missing on {missing} of {len(groups[(rung, cohort)])} run(s): not imputed" if missing else ""])
    T["rungs.tsv"] = (sh, srows)
    T["effcost.tsv"] = (["arm", "rung", "cohort", "metric", "n", "median", "min", "max", "range", "note"], erows)

    # 3. deltas.tsv
    dh = ["arm", "rung", "predecessor", "lever", "counterpart", "cohort", "axis", "lever_phase", "n_rung", "n_pred",
          "median_rung", "median_pred", "delta", "range_rung", "range_pred", "measured_spread", "threshold_2x_spread",
          "status", "predicted_delta", "predicted_resolvable"]
    drows = []
    for (rung, cohort) in sorted(groups):
        lv = levers.get(rung)
        if not lv or not lv["predecessor"]:
            continue
        for ax in AXES:
            a = stats_for(groups, rung, cohort, ax, levers, rung)
            b = stats_for(groups, lv["predecessor"], cohort, ax, levers, rung)
            d = delta(a, b, num(lv.get(PRED_COL[ax])))
            drows.append([lv["arm"], rung, lv["predecessor"], lv["lever"], lv["counterpart"], cohort, ax,
                          lv["phase"] if ax == "lever_phase_s" else "", a["n"], b["n"], fmt(a["median"]), fmt(b["median"]),
                          fmt(d["delta"]), fmt(a["range"]), fmt(b["range"]), fmt(d["measured_spread"]), fmt(d["threshold"]),
                          d["status"], fmt(d["predicted"]), d["predicted_resolvable"] or ("no prediction" if d["predicted"] is None else "")])
    T["deltas.tsv"] = (dh, drows)

    # 5. pairs.tsv
    ph = PAIR_HEAD
    prows = []
    stock = sorted(r for r, x in levers.items() if x["arm"] == "S" and x["lever"] == "stock")
    for cohort in sorted({c for _, c in groups}):
        for fam, ax in PAIR_AXES:
            sstar, sb = endpoints(levers, groups, "S", fam, cohort)
            ostar, ob = endpoints(levers, groups, "O", fam, cohort)
            pairs = [("S vs S*", s, sstar, f"S*: {sb}") for s in stock] + \
                    [("S vs O*", s, ostar, f"O*: {ob}") for s in stock] + [("S* vs O*", sstar, ostar, f"S*: {sb}; O*: {ob}")]
            for name, src, tgt, basis in pairs:
                prows += pair_rows(name, cohort, fam, ax, src, tgt, basis, groups, levers)
    T["pairs.tsv"] = (ph, prows)

    # 6. Law 1 across arms
    l1, det, s5rows = law1(runs, levers, defects)
    T["law1.tsv"] = (["accession", "entries", "arms", "rungs", "reference", "reference_roles", "status", "detail"], l1)
    T["law1-detail.tsv"] = (["accession", "run_id", "node", "arm", "rung", "cohort", "role", "bytes", "sha256",
                             "reference_sha256", "status"], det)
    T["s5-nonpreserving.tsv"] = (["accession", "run_id", "arm", "rung", "cohort", "s5_P", "nproc",
                                  "outputs_equal_reference", "note"], s5rows)

    # 7. endpoint decomposition runs: cold and warm rows
    eg = {}
    for r in runs:
        p = r["params"]
        if p["run_kind"] == "endpoint":
            eg.setdefault((p.get("arm", ""), p["endpoint"], p["rung"], p.get("cohort", ""), p["state"]), []).append(r)
    erows = []
    for k in sorted(eg, key=lambda k: tuple(str(x) for x in k)):
        rs = eg[k]
        metrics = ["wall_s", "billed_usd"] + [f"phase.{n}" for n in sorted({n for r in rs for n in r["phases_run"]})]
        for m in metrics:
            vals = [r["phases_run"].get(m[6:]) if m.startswith("phase.") else r[m] for r in rs]
            s = stats(vals)
            erows.append(list(k) + [m, s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                                    fmt(s["range"]) if s["n"] >= 2 else "n<2"])
    T["endpoints.tsv"] = (["arm", "endpoint", "rung", "cohort", "state", "metric", "n", "median", "min", "max", "range"], erows)

    # 8. spend
    sp = []
    for r in runs:
        p = r["params"]
        inc = "no campaign spend.tsv" if campaign_spend is None else ("yes" if r["run_id"] in campaign_spend else "NO")
        if inc == "NO":
            notes.append(f"{r['run_id']}: not in results/g3/campaign/spend.tsv (rerun make g3-tables)")
        sp.append([r["run_id"], r["gate"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"],
                   p["state"], r["type"], r["nodes"], fmt(r["billed_usd"]), inc])
    tot = sum(r["billed_usd"] for r in runs if r["billed_usd"] is not None)
    nmiss = sum(1 for r in runs if r["billed_usd"] is None)
    sp.append(["TOTAL", "", "", "", "", "", "", "", "", "", fmt(tot), f"{nmiss} run(s) without a bill" if nmiss else ""])
    T["spend.tsv"] = (["run_id", "gate", "arm", "rung", "cohort", "rep", "run_kind", "state", "type", "nodes", "billed_usd",
                       "in_campaign_spend"], sp)
    return T, defects, notes, excl


PAIR_HEAD = ["pair", "cohort", "endpoint_axis", "axis", "source", "target", "endpoint_basis", "row", "step", "rung",
             "predecessor", "lever", "n_rung", "n_pred", "delta", "status", "threshold_2x_spread", "source_median",
             "target_median", "ratio_source_over_target", "sum_of_lever_deltas", "residual_total_minus_sum", "note"]


def pair_rows(name, cohort, fam, ax, src, tgt, basis, groups, levers):
    """One pair on one axis: its lever rows (the rung deltas along tgt's predecessor chain back to
    src) and its total row, beside each other (Law 5)."""
    base = {"pair": name, "cohort": cohort, "endpoint_axis": fam, "axis": ax, "source": src or "", "target": tgt or "",
            "endpoint_basis": basis}
    L = lambda **k: [dict(base, **k).get(h, "") for h in PAIR_HEAD]
    if not src or not tgt:
        return [L(row="total", status="missing endpoint")]
    ch = chain(levers, tgt)
    a, b = stats_for(groups, tgt, cohort, ax, levers, tgt), stats_for(groups, src, cohort, ax, levers, src)
    tot = delta(a, b)
    ratio = (b["median"] / a["median"]) if a["n"] and b["n"] and a["median"] else None
    total = dict(row="total", n_rung=a["n"], n_pred=b["n"], delta=fmt(tot["delta"]), status=tot["status"],
                 threshold_2x_spread=fmt(tot["threshold"]), source_median=fmt(b["median"]), target_median=fmt(a["median"]),
                 ratio_source_over_target=fmt(ratio))
    if src not in ch:
        return [L(note=f"no per-lever path: {src} is not on {tgt}'s predecessor chain ({' <- '.join(ch)}) in "
                       "ladder.levers.tsv; the total alone is not an attribution", **total)]
    steps = list(reversed(ch[:ch.index(src)]))
    rows, ssum, missing = [], 0.0, []
    for i, rung in enumerate(steps, 1):
        lv = levers[rung]
        x = stats_for(groups, rung, cohort, ax, levers, rung)
        y = stats_for(groups, lv["predecessor"], cohort, ax, levers, rung)
        d = delta(x, y)
        if d["delta"] is None:
            missing.append(rung)
        else:
            ssum += d["delta"]
        rows.append(L(row="lever", step=i, rung=rung, predecessor=lv["predecessor"], lever=lv["lever"], n_rung=x["n"],
                      n_pred=y["n"], delta=fmt(d["delta"]), status=d["status"], threshold_2x_spread=fmt(d["threshold"])))
    complete = not missing and tot["delta"] is not None
    rows.append(L(sum_of_lever_deltas=fmt(ssum) if complete else "incomplete",
                  residual_total_minus_sum=fmt(tot["delta"] - ssum) if complete else "",
                  note=(f"steps missing medians: {', '.join(missing)}" if missing else
                        ("source = target: no levers" if not steps else "")), **total))
    return rows


def law1(runs, levers, defects):
    by = {}
    for r in runs:
        for s in r["samples"]:
            outs = s.get("outputs")
            if s.get("rc") not in (0,) or not isinstance(outs, dict) or not s.get("accession"):
                continue  # failed samples and contract errors are defects already
            if not all(isinstance(o, dict) and HEX64.match(str(o.get("sha256", ""))) for o in outs.values()):
                continue
            by.setdefault(str(s["accession"]), []).append((r, s))
    summ, det, s5rows = [], [], []
    for acc in sorted(by):
        ent = sorted(by[acc], key=lambda e: (e[0]["params"].get("arm", "") != "S",
                                             (levers.get(e[0]["params"]["rung"]) or {}).get("lever") != "stock",
                                             e[0]["params"]["rung"], e[0]["run_id"], str(e[1].get("_node"))))
        s5 = lambda e: (e[1].get("s5") or {}).get("status") == "differs"
        refs = [e for e in ent if not s5(e)]
        ref = refs[0] if refs else None
        rmap = {k: v["sha256"] for k, v in ref[1]["outputs"].items()} if ref else {}
        bad, s5n = [], 0
        for r, s in ent:
            omap = {k: v["sha256"] for k, v in s["outputs"].items()}
            same = omap == rmap
            if s5((r, s)):
                s5n += 1
                st = "S5 not output-preserving on this input"
                s5i = s.get("s5") or {}
                s5rows.append([acc, r["run_id"], r["params"].get("arm", ""), r["params"]["rung"], r["params"].get("cohort", ""),
                               s5i.get("P", ""), s5i.get("nproc", ""), "yes" if same else "no",
                               "S5 not output-preserving on this input: kept out of Law 1's DEFECT count and the attribution"])
            elif set(omap) != set(rmap):
                st = (f"DEFECT: file set differs (missing {','.join(sorted(set(rmap) - set(omap))) or '-'}; "
                      f"extra {','.join(sorted(set(omap) - set(rmap))) or '-'})")
                bad.append(f"{r['run_id']}: {st}")
            elif not same:
                st = "DEFECT: sha256 differs on " + ",".join(k for k in sorted(omap) if omap[k] != rmap.get(k))
                bad.append(f"{r['run_id']}: {st}")
            else:
                st = "reference" if (ref and r is ref[0] and s is ref[1]) else "identical"
            for role in sorted(set(omap) | set(rmap)):
                o = s["outputs"].get(role) or {}
                det.append([acc, r["run_id"], s.get("_node", ""), r["params"].get("arm", ""), r["params"]["rung"],
                            r["params"].get("cohort", ""), role, o.get("bytes", ""), o.get("sha256", "absent"),
                            rmap.get(role, "absent"), st])
        for b in bad:
            defects.append(("Law 1", f"{acc} {b}"))
        status = ("DEFECT" if bad else ("identical" if len(ent) - s5n > 1 else "one entry: nothing to compare"))
        summ.append([acc, len(ent), ",".join(sorted({e[0]["params"].get("arm", "") for e in ent})),
                     ",".join(sorted({e[0]["params"]["rung"] for e in ent})),
                     f"{ref[0]['run_id']} ({ref[0]['params']['rung']})" if ref else "none (every entry S5 non-preserving)",
                     ",".join(sorted(rmap)), status,
                     "; ".join(bad) + (f"; {s5n} S5 non-preserving entr{'y' if s5n == 1 else 'ies'} (s5-nonpreserving.tsv)"
                                       if s5n else "")])
    return summ, det, s5rows


# ---------------------------------------------------------------- output
def write_tsv(path, head, rows):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(head)
        w.writerows(rows)


def git(*a):
    try:
        return subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def summary_md(T, defects, notes, excl, runs, commit):
    L = [f"# Ladder tables (generated by scripts/lib/ladder_tables.py)", "",
         f"Generated at {commit or 'unknown commit'}. Do not edit: rerun `make g3-ladder`. Every number is in a table "
         "beside this file; manifest.json lists every input with its sha256.", "",
         f"- Ladder runs found: {len(runs)} ({sum(1 for r in runs if r['params']['run_kind'] == 'ladder')} ladder, "
         f"{sum(1 for r in runs if r['params']['run_kind'] == 'endpoint')} endpoint decomposition).",
         f"- Excluded from the attribution: {len(excl)}" + ("".join(f"\n  - {r['run_id']}: {why}" for r, why in excl)),
         f"- DEFECTs: {len(defects)}" + "".join(f"\n  - {k}: {v}" for k, v in defects[:50]),
         f"- Notes: {len(notes)}" + "".join(f"\n  - {n}" for n in notes[:50]), "",
         "Deltas are labelled resolved only if |delta median| > 2 x max(range of rung, range of predecessor); every other "
         "delta is unresolvable, not a null (deltas.tsv). Pairs carry their per-lever decomposition beside the total "
         "(pairs.tsv); effective cost is per resource, never combined (effcost.tsv, runs.tsv).", ""]
    h, rows = T["pairs.tsv"]
    tot = [r for r in rows if r[7] == "total" and r[3] in ("wall_s", "billed_usd")]
    if tot:
        L += ["## Pair totals (wall_s and billed_usd; their lever rows are in pairs.tsv)", "",
              "| pair | cohort | axis | source | target | delta | status | ratio | sum of lever deltas | note |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for r in tot:
            L.append(f"| {r[0]} | {r[1]} | {r[3]} | {r[4]} | {r[5]} | {r[14]} | {r[15]} | {r[19]} | {r[20]} | {r[22]} |")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", default=os.path.join(ROOT, "results"))
    ap.add_argument("--levers", default=os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"))
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "g3", "ladder"))
    ap.add_argument("--spend", default=None, help="campaign spend.tsv (default <results>/g3/campaign/spend.tsv)")
    a = ap.parse_args(argv)
    rd = Reader()
    levers = load_levers(a.levers, rd)
    runs = discover(a.results, rd)
    spend_p = a.spend or os.path.join(a.results, "g3", "campaign", "spend.tsv")
    cs = None
    if os.path.exists(spend_p):
        cs = {r.get("run") for r in csv.DictReader(rd.text(spend_p).splitlines(), delimiter="\t")}
    T, defects, notes, excl = build(runs, levers, cs)
    if not levers:
        notes.insert(0, f"no lever table at {os.path.relpath(a.levers, ROOT)}: no predecessors, so no deltas or pairs")
    os.makedirs(a.out, exist_ok=True)
    commit = git("rev-parse", "HEAD")
    outs = []
    for name, (h, rows) in T.items():
        write_tsv(os.path.join(a.out, name), h, rows)
        outs.append(name)
    with open(os.path.join(a.out, "summary.md"), "w") as f:
        f.write(summary_md(T, defects, notes, excl, runs, commit))
    outs.append("summary.md")
    of = []
    for n in outs:
        with open(os.path.join(a.out, n), "rb") as f:
            of.append({"path": n, "sha256": hashlib.sha256(f.read()).hexdigest()})
    rel = lambda p: os.path.relpath(p, ROOT) if p.startswith(ROOT) else p
    man = {"generator": "scripts/lib/ladder_tables.py", "commit": commit or None,
           "generator_dirty": bool(git("status", "--porcelain", "--", "scripts/lib/ladder_tables.py")),
           "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "lad_sample_contract_v": CONTRACT_V, "levers": rel(os.path.abspath(a.levers)) if levers else None,
           "runs": [{"run_id": r["run_id"], "dir": rel(os.path.abspath(r["dir"])), "commit": r["commit"],
                     "params": r["params"]} for r in runs],
           "defects": [f"{k}: {v}" for k, v in defects], "notes": notes,
           "inputs": [{"path": rel(p), "bytes": b, "sha256": h} for p, (b, h) in sorted(rd.files.items())],
           "outputs": of}
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(man, f, indent=2)
        f.write("\n")
    print(f"ladder_tables: {len(runs)} ladder run(s), {len(levers)} lever row(s), {len(defects)} DEFECT(s) -> {a.out}/")
    for k, v in defects:
        print(f"ladder_tables: DEFECT ({k}): {v}", file=sys.stderr)
    return 1 if defects else 0


if __name__ == "__main__":
    sys.exit(main())
