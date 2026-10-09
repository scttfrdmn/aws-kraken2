#!/usr/bin/env python3
"""The #25 ladder tables (#52, WP-8; runbook docs/ladder.md, "Ladder tables"). From the record only.

  ladder_tables.py [--results results] [--levers scripts/g3/ladder.levers.tsv]
                   [--modelled results/g3/ladder-modelled.tsv] [--out results/g3/ladder]

Inputs: every ladder run dir under results/<gate>/2026* (a single run's manifest.json, or a
cohort dir's cohort.json with its members' manifests) whose params (manifest "params", else
cohort.json "params", else the rank-0 member's) name a rung; each run's lad-sample lines
(out/**/lad-samples.jsonl, pushed; checked against the `lad-sample {json}` lines streamed into
log/run.log); each run's tables/util.tsv (its fleet row only); the lever table
ladder.levers.tsv; the modelled-values table (optional); results/g3/campaign/spend.tsv (the spend
cross-check); results/cohort/<project>/runs.tsv when a planned accession set is a reference.

Outputs (in --out): runs.tsv, tidy.tsv, rungs.tsv, deltas.tsv, effcost.tsv, pairs.tsv, law1.tsv,
law1-detail.tsv, s5-nonpreserving.tsv, endpoints.tsv, spend.tsv, summary.md, manifest.json.

Definitions (docs/ladder.md, "Ladder tables", is the full statement):
  - wall_s: first instance.launch_time -> last instance.terminated_at over the run's nodes
    (missing if any node lacks either; no fallback).
  - billed_usd: the manifests' cost_usd, summed over a cohort (missing if any node's is).
  - lever_phase_s: the rung's lever phase (ladder.levers.tsv `phase`): run:NAME (manifest phase
    seconds summed per node, max over nodes), sample:NAME (sum of the lad-sample phases.NAME),
    a bare NAME (run if the manifest has it, else sample); A+B sums.
  - Granularity q per axis: wall 2 s; billed price/h x 2 s / 3600 x nodes; run phase 1 s x the
    summed phase entries; sample phase 0.001 s x the summed sample entries; effective cost
    q_billed / U. q over a group = the largest of its runs'.
  - Resolution: a delta is resolved only if |delta| > 2 x max(range of rung, range of
    predecessor, q). Otherwise it is unresolvable (below instrument granularity when q is the
    larger term), and so is any delta with n < 2 on either side. Never a null.
  - Effective cost per resource: util.tsv's fleet cost_usd / U (same node set as U), never combined.
  - Pairs: S vs S*, S vs O*, S* vs O* on the declared endpoints; each total beside its lever rows.
  - Law 1 across arms: per accession, file set and on-node sha256 against a stock reference.
Exit status: 0, or 1 if any DEFECT.
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
S5_FALLBACK = ("none", "gzip")
ARMS = ("S", "O")
RUN_KINDS = ("ladder", "endpoint")
STATES = ("cold", "warm", "cold-local")
ENDPOINT_TAGS = ("S*-time", "S*-cost", "O*-time", "O*-cost")
RAPIDGZIP_LEVER = "rapidgzip"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ROLES = ("output", "report")
Q_WALL = 2.0          # two whole-second timestamps
Q_RUN_PHASE = 1.0     # per manifest phase entry (whole seconds)
Q_SAMPLE_PHASE = 0.001  # per lad-sample phase entry (seconds with 3 decimals)
U_COLS = ["U_cpu", "U_mem_mean", "U_mem_peak", "U_net_baseline", "U_net_peak", "U_net_rx_baseline", "U_net_rx_peak",
          "U_net_tx_baseline", "U_net_tx_peak"]
EFF = [("eff_cpu_usd", "U_cpu"), ("eff_mem_usd", "U_mem_mean"), ("eff_net_baseline_usd", "U_net_baseline"),
       ("eff_net_peak_usd", "U_net_peak"), ("eff_net_rx_baseline_usd", "U_net_rx_baseline"),
       ("eff_net_rx_peak_usd", "U_net_rx_peak"), ("eff_net_tx_baseline_usd", "U_net_tx_baseline"),
       ("eff_net_tx_peak_usd", "U_net_tx_peak")]
EFF_U = dict(EFF)
AXES = ["wall_s", "billed_usd", "lever_phase_s"]
PRED_COL = {"wall_s": "pred_wall_s", "billed_usd": "pred_usd", "lever_phase_s": "pred_phase_s"}
PAIR_AXES = [("time", "wall_s"), ("cost", "billed_usd")] + [("cost", e) for e, _ in EFF]


# ---------------------------------------------------------------- small helpers
def ts(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


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


def split_tags(v):
    return [t.strip() for t in re.split(r"[;,]", str(v or "")) if t.strip()]


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
    """params: lowercase keys, a leading lad_/ak2_lad_/ak2_ stripped; ints parsed where they parse
    (left as given otherwise, for params_errors to name); defaults for the optional keys."""
    if not isinstance(p, dict):
        return None
    out = {}
    for k, v in p.items():
        k2 = k.lower()
        for pre in ("ak2_lad_", "lad_", "ak2_"):
            if k2.startswith(pre):
                k2 = k2[len(pre):]
                break
        out[k2] = v
    if not out.get("rung"):
        return None
    for k in ("cohort", "rep"):
        if k in out and not is_int(out[k]):
            try:
                out[k] = int(str(out[k]))
            except ValueError:
                pass
    out.setdefault("rep", 1)
    out.setdefault("run_kind", "ladder")
    out.setdefault("state", "cold")
    out.setdefault("endpoint", "")
    return out


def params_errors(p, levers):
    e = []
    if p.get("arm") not in ARMS:
        e.append(f"params arm {p.get('arm')!r} not in {'/'.join(ARMS)}")
    if not (is_int(p.get("cohort")) and p["cohort"] >= 1):
        e.append(f"params cohort {p.get('cohort')!r} is not an integer >= 1")
    if not (is_int(p.get("rep")) and p["rep"] >= 1):
        e.append(f"params rep {p.get('rep')!r} is not an integer >= 1")
    if p.get("run_kind") not in RUN_KINDS:
        e.append(f"params run_kind {p.get('run_kind')!r} not in {'/'.join(RUN_KINDS)}")
    if p.get("state") not in STATES:
        e.append(f"params state {p.get('state')!r} not in {'/'.join(STATES)}")
    tags = split_tags(p.get("endpoint"))
    if p.get("run_kind") == "endpoint":
        if not tags or any(t not in ENDPOINT_TAGS for t in tags):
            e.append(f"params endpoint {p.get('endpoint')!r}: an endpoint run needs one or more of {', '.join(ENDPOINT_TAGS)}")
        elif any(not t.startswith(str(p.get("arm")) + "*") for t in tags):
            e.append(f"params endpoint {p.get('endpoint')!r} is not on arm {p.get('arm')}")
    elif tags:
        e.append(f"params endpoint {p.get('endpoint')!r} on a ladder run (endpoints are run_kind endpoint)")
    lv = levers.get(p.get("rung"))
    if lv and lv["arm"] != p.get("arm"):
        e.append(f"params arm {p.get('arm')!r} but ladder.levers.tsv puts {p['rung']} on arm {lv['arm']}")
    return e


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


def declared_endpoints(levers):
    """(tag, cohort or None) -> rung, from the `endpoint` column: `S*-time` (every cohort) or
    `c10:S*-time` (cohort 10). Returns (map, errors): two rungs declaring the same endpoint for the
    same cohort is an error."""
    m, errs = {}, []
    for rung, lv in sorted(levers.items()):
        for t in split_tags(lv.get("endpoint")):
            c = None
            mm = re.match(r"^c(\d+):(.+)$", t)
            if mm:
                c, t = int(mm.group(1)), mm.group(2)
            if t not in ENDPOINT_TAGS:
                errs.append(f"ladder.levers.tsv: {rung} declares an unknown endpoint {t!r}")
                continue
            if not t.startswith(lv["arm"] + "*"):
                errs.append(f"ladder.levers.tsv: {rung} (arm {lv['arm']}) declares {t}")
                continue
            k = (t, c)
            if k in m and m[k] != rung:
                errs.append(f"ladder.levers.tsv: {t}{'' if c is None else f' at cohort {c}'} declared by both {m[k]} and {rung}")
                continue
            m[k] = rung
    return m, errs


def endpoint_rung(emap, tag, cohort):
    if (tag, cohort) in emap:
        return emap[(tag, cohort)], f"declared for c{cohort}"
    if (tag, None) in emap:
        return emap[(tag, None)], "declared"
    return None, "endpoint not declared"


def stock_rungs(levers):
    """The stock rungs: the S root(s) with lever `stock` (S0-T1) and their `threads` children
    (S0-Tv). The sources of pairs 1 and 2 and the candidates for the Law 1 reference."""
    roots = {r for r, x in levers.items() if x["arm"] == "S" and x["lever"] == "stock" and not x["predecessor"]}
    return sorted(roots | {r for r, x in levers.items() if x["arm"] == "S" and x["lever"] == "threads"
                           and x["predecessor"] in roots})


def chain(levers, target):
    out, seen, r = [], set(), target
    while r and r not in seen:
        seen.add(r)
        out.append(r)
        r = (levers.get(r) or {}).get("predecessor", "")
    return out


def has_rapidgzip(levers, rung):
    """An S rung whose lever, or an ancestor's, is rapidgzip (S5 and its descendants on ladder 1)."""
    return any((levers.get(r) or {}).get("arm") == "S" and (levers.get(r) or {}).get("lever") == RAPIDGZIP_LEVER
               for r in chain(levers, rung)) and (levers.get(rung) or {}).get("arm") == "S"


def load_modelled(path, rd):
    """(rung, cohort, axis) -> {value, basis, source}. Columns: arm, rung, cohort, axis, value,
    basis, source. Missing file: {}."""
    if not path or not os.path.exists(path):
        return {}
    out = {}
    lines = [ln for ln in rd.text(path).splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    for f in csv.DictReader(lines, delimiter="\t"):
        v, c = num(f.get("value")), f.get("cohort", "")
        if v is None or not c.isdigit():
            continue
        out[(f.get("rung", ""), int(c), f.get("axis", ""))] = {"value": v, "basis": f.get("basis", "modelled"),
                                                                 "source": f.get("source", "")}
    return out


# ---------------------------------------------------------------- one run
def lad_lines(member_dir, rd, notes, label):
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
    sums, counts = {}, {}
    for p in man.get("phases") or []:
        s = num(p.get("seconds"))
        if p.get("phase") and s is not None:
            sums[p["phase"]] = sums.get(p["phase"], 0.0) + s
            counts[p["phase"]] = counts.get(p["phase"], 0) + 1
    return sums, counts


def read_util(d, rd):
    """The fleet row of d/tables/util.tsv, as {U_*, cost_usd, coverage}; None if there is none."""
    p = os.path.join(d, "tables", "util.tsv")
    if not os.path.exists(p):
        return None
    rows = [r for r in csv.DictReader(rd.text(p).splitlines(), delimiter="\t") if r.get("scope") == "fleet"]
    if not rows:
        return None
    r = rows[0]
    out = {k: num(r.get(k)) for k in U_COLS}
    out["cost_usd"] = num(r.get("cost_usd"))
    out["coverage"] = r.get("coverage", "")
    return out


def planned_set(man, results, rd, notes):
    """The run's planned accessions: manifest sample_accessions, else its resolved reference
    (@project:a-b over the recorded runs.tsv). None if neither."""
    acc = man.get("sample_accessions")
    if isinstance(acc, list) and acc:
        return set(map(str, acc))
    ref = man.get("sample_accessions_ref") or {}
    m = re.match(r"^@([A-Za-z0-9_.-]+):(\d+)-(\d+)$", str(ref.get("ref", "")))
    if not m:
        return None
    rel = ref.get("runs_tsv") or f"results/cohort/{m.group(1)}/runs.tsv"
    p = os.path.join(os.path.dirname(os.path.abspath(results)), rel)
    if not os.path.exists(p):
        notes.append(f"planned set {ref.get('ref')}: {rel} not found")
        return None
    a, b = int(m.group(2)), int(m.group(3))
    rows = [r for r in csv.DictReader(rd.text(p).splitlines(), delimiter="\t") if (r.get("rank") or "").isdigit()]
    got = [r["run"] for r in rows if a <= int(r["rank"]) <= b]
    if len(got) != b - a + 1:
        notes.append(f"planned set {ref.get('ref')}: {rel} has {len(got)} of {b - a + 1} ranks")
        return None
    return set(got)


def read_run(d, rd, results):
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
           "params": params, "notes": notes, "nodes": len(members), "exclude": []}
    m0 = members[0][2] if members else {}
    inst = m0.get("instance") or {}
    run.update(type=inst.get("type"), az=inst.get("az"), region=m0.get("region"),
               price=num(m0.get("truffle_price_usd_per_hour")))
    launches = [ts((m.get("instance") or {}).get("launch_time")) for _, _, m in members]
    terms = [ts((m.get("instance") or {}).get("terminated_at")) for _, _, m in members]
    if members and None not in launches and None not in terms:
        run["wall_s"] = max(terms) - min(launches)
    else:
        run["wall_s"] = None
        notes.append("instance.launch_time or instance.terminated_at missing on a node: wall missing (no fallback)")
    costs = [num(m.get("cost_usd")) for _, _, m in members]
    if members and None not in costs:
        run["billed_usd"] = sum(costs)
    else:
        run["billed_usd"] = None
        notes.append("cost_usd missing on a node: billed missing (not imputed)")
    ph, pc = {}, {}
    for _, _, m in members:
        s, c = phase_sums(m)
        for k, v in s.items():
            if v >= ph.get(k, -1):
                ph[k], pc[k] = v, c[k]
    run["phases_run"], run["phase_entries"] = ph, pc
    planned = set()
    for _, _, m in members:
        x = planned_set(m, results, rd, notes)
        if x is None:
            planned = None
            break
        planned |= x
    run["planned"] = planned if members else None
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
        uv, c = (None, None) if u is None else (u.get(uk), u.get("cost_usd"))
        run["eff"][e] = None if uv is None or c is None else (float("inf") if uv == 0 else c / uv)
    return run


def discover(results, rd):
    runs = []
    for d in sorted(glob.glob(os.path.join(results, "*", "2026*"))):
        if not os.path.isdir(d) or re.search(r"-n\d+-r\d+$", os.path.basename(d)):
            continue  # cohort members are read through their cohort
        sub = Reader()  # only a ladder run's files are inputs
        r = read_run(d, sub, results)
        if r:
            rd.files.update(sub.files)
            runs.append(r)
    return runs


# ---------------------------------------------------------------- contract
def sample_errors(run, s):
    p = run["params"]
    where = f"{run['run_id']} {s.get('_node')} {s.get('accession', '?')}"
    errs = []
    for k in ("v", "arm", "rung", "cohort", "accession", "pairs", "rc", "phases", "outputs", "s5"):
        if k not in s:
            errs.append(f"{where}: missing {k}")
    if "v" in s and not (is_int(s["v"]) and s["v"] == CONTRACT_V):
        errs.append(f"{where}: v {s['v']!r} is not {CONTRACT_V}")
    for k in ("arm", "rung", "cohort"):
        if k in s and str(s[k]) != str(p.get(k)):
            errs.append(f"{where}: {k} {s[k]!r} != the run's params {p.get(k)!r}")
    if "accession" in s and not (isinstance(s["accession"], str) and s["accession"]):
        errs.append(f"{where}: accession is not a non-empty string")
    if "pairs" in s and not (is_int(s["pairs"]) and s["pairs"] >= 0):
        errs.append(f"{where}: pairs is not a non-negative integer")
    if "rc" in s and not is_int(s["rc"]):
        errs.append(f"{where}: rc {s['rc']!r} is not an integer")
    if "phases" in s and not (isinstance(s["phases"], dict) and
                              all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in s["phases"].values())):
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
                if not isinstance(o, dict) or not HEX64.match(str(o.get("sha256", ""))) or not is_int(o.get("bytes")):
                    errs.append(f"{where}: outputs.{role} needs bytes (int) and sha256 (64 lowercase hex)")
    s5 = s.get("s5")
    if "s5" in s:
        if not (isinstance(s5, dict) and s5.get("status") in S5_STATUS):
            errs.append(f"{where}: s5.status must be one of {', '.join(S5_STATUS)}")
        elif s5.get("fallback", "none") not in S5_FALLBACK:
            errs.append(f"{where}: s5.fallback {s5.get('fallback')!r} not in {'/'.join(S5_FALLBACK)}")
        elif s5.get("fallback", "none") == "gzip" and s5.get("status") != "differs":
            errs.append(f"{where}: s5.fallback gzip without s5.status differs")
    return errs


def contract_errors(run):
    errs = []
    for s in run["samples"]:
        errs += sample_errors(run, s)
    return errs


def s5_of(s):
    x = s.get("s5") if isinstance(s.get("s5"), dict) else {}
    return x.get("status"), x.get("fallback", "none")


def validate(runs, levers, defects):
    """Contract, failed samples and completeness. Each DEFECT also excludes its run."""
    for r in runs:
        rid = r["run_id"]
        for e in params_errors(r["params"], levers):
            defects.append(("contract", f"{rid}: {e}"))
            r["exclude"].append(f"DEFECT (contract): {e}")
        bad = set()
        for s in r["samples"]:
            es = sample_errors(r, s)
            for e in es:
                defects.append(("contract", e))
            if es:
                bad.add(id(s))
                r["exclude"].append("DEFECT (contract) in its lad-sample lines")
            elif s["rc"] != 0:
                defects.append(("sample failed", f"{rid} {s['accession']}: rc {s['rc']}"))
                r["exclude"].append(f"DEFECT (sample failed): {s['accession']} rc {s['rc']}")
        r["bad_samples"] = bad
        got = [str(s.get("accession")) for s in r["samples"]]
        if r["planned"] is None:
            defects.append(("incomplete", f"{rid}: no planned accession set (sample_accessions or its reference)"))
            r["exclude"].append("DEFECT (incomplete): no planned accession set")
        elif set(got) != r["planned"]:
            miss, extra = sorted(r["planned"] - set(got)), sorted(set(got) - r["planned"])
            e = f"{len(set(got) & r['planned'])} of {len(r['planned'])} planned samples" + \
                (f"; missing {','.join(miss[:10])}{'...' if len(miss) > 10 else ''}" if miss else "") + \
                (f"; unplanned {','.join(extra[:10])}" if extra else "")
            defects.append(("incomplete", f"{rid}: {e}"))
            r["exclude"].append(f"DEFECT (incomplete): {e}")
        if len(got) != len(set(got)):
            r["notes"].append(f"{len(got) - len(set(got))} duplicate lad-sample accession line(s)")
        if r["params"]["run_kind"] == "ladder" and r["params"]["state"] != "cold":
            r["exclude"].append(f"state {r['params']['state']}: ladder runs are cold")
        if r["params"]["rung"] not in levers:
            r["notes"].append(f"rung {r['params']['rung']} is not in ladder.levers.tsv")
        r["exclude"] = list(dict.fromkeys(r["exclude"]))


# ---------------------------------------------------------------- axes, stats, deltas
def phase_parts(spec):
    if not spec:
        return []
    scope, name = (spec.split(":", 1) if ":" in spec else ("", spec))
    return [(scope, part) for part in name.split("+")]


def phase_value(run, spec):
    """(seconds, granularity) of a lever phase, or (None, None)."""
    parts = phase_parts(spec)
    if not parts:
        return None, None
    total, q = 0.0, 0.0
    for scope, part in parts:
        if scope == "run" or (scope == "" and part in run["phases_run"]):
            v = run["phases_run"].get(part)
            q += Q_RUN_PHASE * run["phase_entries"].get(part, 0)
        else:
            vals = [s["phases"][part] for s in run["samples"] if isinstance(s.get("phases"), dict) and part in s["phases"]]
            v = sum(vals) if vals else None
            q += Q_SAMPLE_PHASE * len(vals)
        if v is None:
            return None, None
        total += v
    return total, q


def q_billed(run):
    return None if run["price"] is None or not run["nodes"] else run["price"] * 2.0 / 3600.0 * run["nodes"]


def axis_value(run, axis, levers, phase_rung):
    """(value, granularity q) of a run on an axis."""
    if axis == "wall_s":
        return run["wall_s"], Q_WALL
    if axis == "billed_usd":
        return run["billed_usd"], q_billed(run)
    if axis == "lever_phase_s":
        return phase_value(run, (levers.get(phase_rung) or {}).get("phase"))
    if axis in run["eff"]:
        v, u, qb = run["eff"][axis], (run["util"] or {}).get(EFF_U[axis]), q_billed(run)
        return v, (None if v is None or qb is None or not u else qb / u)
    if run["util"] is not None and axis in U_COLS:
        return run["util"].get(axis), None
    return None, None


def stats(pairs):
    """pairs: [(value, q)]. q of the group = the largest q of its valued runs (None if any is None)."""
    v = [(x, q) for x, q in pairs if x is not None]
    if not v:
        return {"n": 0, "median": None, "min": None, "max": None, "range": None, "q": None, "basis": "measured"}
    xs = [x for x, _ in v]
    qs = [q for _, q in v]
    return {"n": len(xs), "median": statistics.median(xs), "min": min(xs), "max": max(xs),
            "range": (max(xs) - min(xs)) if len(xs) >= 2 else None, "q": None if None in qs else max(qs), "basis": "measured"}


def delta(a, b, predicted=None):
    """a: the rung's (or target's) stats, b: the predecessor's (or source's). The resolution rule."""
    d = {"delta": None, "status": "", "measured_spread": None, "q": None, "threshold": None, "predicted": predicted,
         "predicted_resolvable": ""}
    if not a["n"] or not b["n"]:
        d["status"] = "missing: " + " and ".join(w for w, s in (("rung", a), ("predecessor", b)) if not s["n"]) + " has no runs"
        return d
    d["delta"] = a["median"] - b["median"]
    if "modelled" in (a["basis"], b["basis"]):
        d["status"] = "modelled (flagged): not a measurement, not resolvable"
        return d
    if a["n"] < 2 or b["n"] < 2:
        d["status"] = f"unresolvable: n < 2 (n {a['n']} vs {b['n']}), no spread"
        return d
    d["measured_spread"] = max(a["range"], b["range"])
    if a["q"] is None or b["q"] is None:
        d["status"] = "unresolvable: instrument granularity unknown"
        return d
    d["q"] = max(a["q"], b["q"])
    d["threshold"] = 2 * max(d["measured_spread"], d["q"])
    if abs(d["delta"]) > d["threshold"]:
        d["status"] = "resolved"
    elif d["q"] >= d["measured_spread"]:
        d["status"] = "unresolvable: below instrument granularity"
    else:
        d["status"] = "unresolvable: |delta| <= 2 x spread"
    if predicted is not None:
        d["predicted_resolvable"] = "yes" if abs(predicted) > d["threshold"] else "no"
    return d


class Groups:
    """The runs entering the attribution, by (rung, cohort), and the cold endpoint runs by
    (tag, rung, cohort); modelled values fill a (rung, cohort, axis) with no measured run."""

    def __init__(self, runs, levers, modelled):
        self.levers, self.modelled = levers, modelled
        self.g, self.e = {}, {}
        for r in runs:
            if r["exclude"]:
                continue
            p = r["params"]
            if p["run_kind"] == "ladder":
                self.g.setdefault((p["rung"], p["cohort"]), []).append(r)
            elif p["state"] == "cold":
                for t in split_tags(p["endpoint"]):
                    self.e.setdefault((t, p["rung"], p["cohort"]), []).append(r)

    def runs(self, rung, cohort):
        return self.g.get((rung, cohort), [])

    def stats(self, rung, cohort, axis, phase_rung=None):
        s = stats([axis_value(r, axis, self.levers, phase_rung or rung) for r in self.runs(rung, cohort)])
        m = self.modelled.get((rung, cohort, axis))
        if not s["n"] and m:
            s = {"n": 1, "median": m["value"], "min": m["value"], "max": m["value"], "range": None, "q": None,
                 "basis": "modelled", "basis_note": f"modelled (flagged): {m['basis']}; source {m['source'] or '-'}"}
        return s

    def endpoint_stats(self, tag, rung, cohort, axis):
        rs = self.e.get((tag, rung, cohort), [])
        return stats([axis_value(r, axis, self.levers, rung) for r in rs]), rs


def coverage(runs):
    c = sorted({r["util_coverage"] for r in runs})
    return " | ".join(c)


# ---------------------------------------------------------------- the tables
PAIR_HEAD = ["pair", "cohort", "endpoint_axis", "axis", "source", "target", "endpoint_basis", "row", "step", "rung",
             "predecessor", "lever", "n_rung", "n_pred", "delta", "status", "granularity_q", "threshold",
             "source_median", "target_median", "ratio_source_over_target", "sum_of_lever_deltas",
             "residual_total_minus_sum", "util_coverage", "note"]


def pair_rows(name, cohort, fam, ax, src, src_tag, src_basis, tgt, tgt_tag, tgt_basis, G):
    """One pair on one axis: its lever rows (the rung deltas along tgt's predecessor chain back to
    src) and its total row, beside each other (Law 5). An endpoint's total comes from its cold
    endpoint runs where they exist, else from its ladder rung's runs."""
    levers = G.levers
    basis = f"source {src or '-'}: {src_basis}; target {tgt or '-'}: {tgt_basis}"
    base = {"pair": name, "cohort": cohort, "endpoint_axis": fam, "axis": ax, "source": src or "", "target": tgt or "",
            "endpoint_basis": basis}
    L = lambda **k: [dict(base, **k).get(h, "") for h in PAIR_HEAD]
    eff = ax.startswith("eff_")
    if not src or not tgt:
        return [L(row="total", status="endpoint not declared")]

    def side(rung, tag):
        if tag:
            s, rs = G.endpoint_stats(tag, rung, cohort, ax)
            if s["n"]:
                return s, rs, f"{tag} endpoint runs (n {s['n']})"
        return G.stats(rung, cohort, ax), G.runs(rung, cohort), "ladder runs"
    a, ar, aw = side(tgt, tgt_tag)
    b, br, bw = side(src, src_tag)
    tot = delta(a, b)
    ratio = (b["median"] / a["median"]) if a["n"] and b["n"] and a["median"] else None
    total = dict(row="total", n_rung=a["n"], n_pred=b["n"], delta=fmt(tot["delta"]), status=tot["status"],
                 granularity_q=fmt(tot["q"]), threshold=fmt(tot["threshold"]), source_median=fmt(b["median"]),
                 target_median=fmt(a["median"]), ratio_source_over_target=fmt(ratio),
                 util_coverage=coverage(ar + br) if eff else "")
    ch = chain(levers, tgt)
    if src not in ch:
        return [L(note=f"totals: target from {aw}, source from {bw}; no per-lever path: {src} is not on {tgt}'s "
                       f"predecessor chain ({' <- '.join(ch)}) in ladder.levers.tsv; the total alone is not an attribution",
                  **total)]
    steps = list(reversed(ch[:ch.index(src)]))
    rows, ssum, missing = [], 0.0, []
    for i, rung in enumerate(steps, 1):
        lv = levers[rung]
        x, y = G.stats(rung, cohort, ax), G.stats(lv["predecessor"], cohort, ax, rung)
        d = delta(x, y)
        if d["delta"] is None:
            missing.append(rung)
        else:
            ssum += d["delta"]
        rows.append(L(row="lever", step=i, rung=rung, predecessor=lv["predecessor"], lever=lv["lever"], n_rung=x["n"],
                      n_pred=y["n"], delta=fmt(d["delta"]), status=d["status"], granularity_q=fmt(d["q"]),
                      threshold=fmt(d["threshold"]),
                      util_coverage=coverage(G.runs(rung, cohort) + G.runs(lv["predecessor"], cohort)) if eff else ""))
    complete = not missing and tot["delta"] is not None
    ident = aw == "ladder runs" and bw == "ladder runs"
    note = f"totals: target from {aw}, source from {bw}"
    if missing:
        note += f"; steps missing medians: {', '.join(missing)}"
    elif not steps:
        note += "; source = target: no levers"
    elif complete:
        note += ("; residual is an identity (both totals are ladder medians, so the lever deltas telescope)" if ident
                 else "; residual = endpoint-run total minus the ladder's lever deltas")
    rows.append(L(sum_of_lever_deltas=fmt(ssum) if complete else "incomplete",
                  residual_total_minus_sum=fmt(tot["delta"] - ssum) if complete else "", note=note, **total))
    return rows


def law1(runs, levers, defects, notes):
    """Per accession: file set and sha256 of every successful, contract-clean sample against a
    stock reference. Also marks the runs S5's rule excludes from the attribution."""
    stock = set(stock_rungs(levers))
    by = {}
    for r in runs:
        for s in r["samples"]:
            if id(s) in r.get("bad_samples", set()) or s.get("rc") != 0:
                continue
            by.setdefault(str(s["accession"]), []).append((r, s))
    summ, det, s5rows = [], [], []
    differs = lambda s: s5_of(s)[0] == "differs" and s5_of(s)[1] != "gzip"
    for acc in sorted(by):
        ent = sorted(by[acc], key=lambda e: (e[0]["params"]["arm"] != "S", e[0]["params"]["rung"] not in stock,
                                             e[0]["params"]["rung"], e[0]["run_id"], str(e[1].get("_node"))))
        s_ok = [e for e in ent if e[0]["params"]["arm"] == "S" and not differs(e[1])]
        on_o = any(e[0]["params"]["arm"] == "O" for e in ent)
        ref = s_ok[0] if s_ok else None
        ref_stock = bool(ref and ref[0]["params"]["rung"] in stock)
        rmap = {k: v["sha256"] for k, v in ref[1]["outputs"].items()} if ref else {}
        bad, n_s5 = [], 0
        if on_o and not ref_stock:
            bad.append("no stock reference for an accession on the O arm" + ("" if ref else " (no S-arm entry)"))
        for r, s in ent:
            omap = {k: v["sha256"] for k, v in s["outputs"].items()}
            arm, rung = r["params"]["arm"], r["params"]["rung"]
            cmp_to, cmp_map, why = ref, rmap, "reference"
            if differs(s) and arm == "O":
                same = [e for e in ent if e[0]["params"]["arm"] == "S" and differs(e[1])]
                if not same:
                    st = "DEFECT: s5 differs on the O arm and no S entry has the same decompressor status"
                    bad.append(f"{r['run_id']}: {st}")
                    cmp_to = None
                else:
                    cmp_to, why = same[0], "the S entry with the same decompressor status"
                    cmp_map = {k: v["sha256"] for k, v in same[0][1]["outputs"].items()}
            if cmp_to is None and not (differs(s) and arm == "O"):
                st = "no upstream reference"
            elif cmp_to is None:
                pass
            elif r is cmp_to[0] and s is cmp_to[1]:
                st = "reference"
            elif set(omap) != set(cmp_map):
                st = (f"DEFECT: file set differs from {why} (missing {','.join(sorted(set(cmp_map) - set(omap))) or '-'}; "
                      f"extra {','.join(sorted(set(omap) - set(cmp_map))) or '-'})")
            elif omap != cmp_map:
                st = f"DEFECT: sha256 differs from {why} on " + ",".join(k for k in sorted(omap) if omap[k] != cmp_map.get(k))
            else:
                st = "identical" if why == "reference" else f"identical to {why} ({cmp_to[0]['run_id']})"
            if differs(s) and arm == "S":
                n_s5 += 1
                eq = cmp_to is not None and omap == cmp_map
                if has_rapidgzip(levers, rung) and not eq and cmp_to is not None:
                    st = "S5 not output-preserving on this input"
                    r["exclude"].append(f"S5 not output-preserving on {acc} (no gzip fallback)")
                elif eq:
                    r["notes"].append(f"{acc}: s5 differs with no fallback, but the outputs equal the reference")
                s5rows.append([acc, r["run_id"], arm, rung, r["params"]["cohort"], "differs", s5_of(s)[1],
                               (s.get("s5") or {}).get("P", ""), (s.get("s5") or {}).get("nproc", ""),
                               "yes" if eq else "no", st])
            elif differs(s) and arm == "O" and st.startswith("identical"):
                r["exclude"].append(f"{acc}: s5 differs (no gzip fallback): measured on the same truncated input as {why}")
            if s5_of(s) == ("differs", "gzip"):
                s5rows.append([acc, r["run_id"], arm, rung, r["params"]["cohort"], "differs", "gzip",
                               (s.get("s5") or {}).get("P", ""), (s.get("s5") or {}).get("nproc", ""),
                               "yes" if omap == rmap else "no", st])
            if st.startswith("DEFECT") and f"{r['run_id']}: {st}" not in bad:
                bad.append(f"{r['run_id']}: {st}")
            for role in sorted(set(omap) | set(cmp_map)):
                o = s["outputs"].get(role) or {}
                det.append([acc, r["run_id"], s.get("_node", ""), arm, rung, r["params"]["cohort"], role, o.get("bytes", ""),
                            o.get("sha256", "absent"), cmp_map.get(role, "absent"), st])
        for b in bad:
            defects.append(("Law 1", f"{acc} {b}"))
        if bad:
            status = "DEFECT"
        elif not ref:
            status = "no upstream reference"
        elif len(ent) - n_s5 > 1:
            status = "identical"
        else:
            status = "one entry: nothing to compare"
        summ.append([acc, len(ent), ",".join(sorted({e[0]["params"]["arm"] for e in ent})),
                     ",".join(sorted({e[0]["params"]["rung"] for e in ent})),
                     f"{ref[0]['run_id']} ({ref[0]['params']['rung']}{'' if ref_stock else ', not a stock rung'})" if ref
                     else "none", ",".join(sorted(rmap)), status,
                     "; ".join(bad) + (f"; {n_s5} S-arm s5-differs entr{'y' if n_s5 == 1 else 'ies'} (s5-nonpreserving.tsv)"
                                       if n_s5 else "")])
    for r in runs:
        r["exclude"] = list(dict.fromkeys(r["exclude"]))
    return summ, det, s5rows


def s5_findings(runs, levers):
    """Against the lever: per S rung with rapidgzip, inputs whose identity check failed and fell
    back to gzip (N of M)."""
    out = []
    by = {}
    for r in runs:
        if r["params"].get("arm") == "S" and has_rapidgzip(levers, r["params"]["rung"]):
            for s in r["samples"]:
                if "accession" in s:
                    x = by.setdefault(r["params"]["rung"], [set(), set()])
                    x[1].add(str(s["accession"]))
                    if s5_of(s) == ("differs", "gzip"):
                        x[0].add(str(s["accession"]))
    for rung, (fb, allacc) in sorted(by.items()):
        if fb:
            out.append(f"{rung}: S5 not output-preserving on {len(fb)} of {len(allacc)} inputs (fell back to gzip): "
                       f"{', '.join(sorted(fb))}")
    return out


def build(runs, levers, campaign_spend=None, modelled=None):
    modelled = modelled or {}
    T, defects, notes = {}, [], []
    emap, eerr = declared_endpoints(levers)
    for e in eerr:
        defects.append(("levers", e))
    validate(runs, levers, defects)
    l1, det, s5rows = law1(runs, levers, defects, notes)
    G = Groups(runs, levers, modelled)

    # 1. runs.tsv and tidy.tsv
    rh = ["run_id", "gate", "kind", "arm", "rung", "cohort", "rep", "run_kind", "endpoint", "state", "type", "nodes", "az",
          "commit", "price_usd_per_h", "wall_s", "billed_usd", "lever_phase", "lever_phase_s", "planned_samples", "samples",
          "pairs"] + U_COLS + ["util_cost_usd"] + [e for e, _ in EFF] + ["util_coverage", "in_attribution", "notes"]
    rows, tidy = [], []
    for r in runs:
        p = r["params"]
        u = r["util"] or {}
        lp = (levers.get(p["rung"]) or {}).get("phase", "")
        pairs = sum(s["pairs"] for s in r["samples"] if is_int(s.get("pairs")))
        if r["exclude"]:
            inattr = "no: " + "; ".join(r["exclude"])
        elif p["run_kind"] == "endpoint":
            inattr = "endpoint run" + (" (cold: endpoint totals)" if p["state"] == "cold" else f" ({p['state']}: decomposition only)")
        else:
            inattr = "yes"
        row = [r["run_id"], r["gate"], r["kind"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"],
               p["endpoint"], p["state"], r["type"], r["nodes"], r["az"], r["commit"], fmt(r["price"], 4),
               fmt(r["wall_s"], 1), fmt(r["billed_usd"]), lp, fmt(phase_value(r, lp)[0], 3),
               "" if r["planned"] is None else len(r["planned"]), len(r["samples"]), pairs] + \
              [fmt(u.get(k)) for k in U_COLS] + [fmt(u.get("cost_usd"))] + [fmt(r["eff"][e]) for e, _ in EFF] + \
              [r["util_coverage"], inattr, "; ".join(r["notes"])]
        rows.append(row)
        base = [r["run_id"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"], p["state"]]
        for k, v in (("wall_s", fmt(r["wall_s"], 1)), ("billed_usd", fmt(r["billed_usd"]))):
            tidy.append(base + ["", "", "", k, v if v != "" else "missing"])
        for k in U_COLS + ["cost_usd"]:
            tidy.append(base + ["", "", "", "util." + k if k == "cost_usd" else k,
                                fmt(u.get(k)) if r["util"] else "missing"])
        for e, _ in EFF:
            tidy.append(base + ["", "", "", e, fmt(r["eff"][e]) if r["util"] else "missing"])
        for k, v in sorted(r["phases_run"].items()):
            tidy.append(base + ["", "", "", f"phase.{k}", fmt(v, 3)])
        for s in r["samples"]:
            sb = base + [s.get("_node", ""), s.get("accession", ""), s.get("idx", "")]
            tidy.append(sb + ["pairs", s.get("pairs", "")])
            tidy.append(sb + ["rc", s.get("rc", "")])
            for k, v in sorted((s.get("phases") or {}).items() if isinstance(s.get("phases"), dict) else []):
                tidy.append(sb + [f"phase.{k}", v])
            for role, o in sorted((s.get("outputs") or {}).items() if isinstance(s.get("outputs"), dict) else []):
                if isinstance(o, dict):
                    tidy.append(sb + [f"output.{role}.bytes", o.get("bytes", "")])
                    tidy.append(sb + [f"output.{role}.sha256", o.get("sha256", "")])
            st, fb = s5_of(s)
            tidy.append(sb + ["s5.status", st or ""])
            tidy.append(sb + ["s5.fallback", fb or ""])
    T["runs.tsv"] = (rh, rows)
    T["tidy.tsv"] = (["run_id", "arm", "rung", "cohort", "rep", "run_kind", "state", "node", "accession", "idx", "metric",
                      "value"], tidy)

    keys = sorted(set(G.g) | {(r, c) for r, c, _ in modelled})
    # 2. rungs.tsv (and 4. effcost.tsv)
    srows, erows = [], []
    for (rung, cohort) in keys:
        arm = (levers.get(rung) or {}).get("arm", rung[:1])
        for ax in AXES:
            s = G.stats(rung, cohort, ax)
            srows.append([arm, rung, cohort, ax, (levers.get(rung) or {}).get("phase", "") if ax == "lever_phase_s" else "",
                          s.get("basis_note", "measured"), s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2", fmt(s["q"])])
        rs = G.runs(rung, cohort)
        missing = sum(1 for r in rs if r["util"] is None)
        for ax in U_COLS + [e for e, _ in EFF]:
            s = G.stats(rung, cohort, ax)
            erows.append([arm, rung, cohort, ax, s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2", fmt(s["q"]), coverage(rs),
                          f"util missing on {missing} of {len(rs)} run(s): not imputed" if missing else ""])
    T["rungs.tsv"] = (["arm", "rung", "cohort", "axis", "lever_phase", "basis", "n", "median", "min", "max", "range",
                       "granularity_q"], srows)
    T["effcost.tsv"] = (["arm", "rung", "cohort", "metric", "n", "median", "min", "max", "range", "granularity_q",
                         "util_coverage", "note"], erows)

    # 3. deltas.tsv
    dh = ["arm", "rung", "predecessor", "lever", "counterpart", "cohort", "axis", "lever_phase", "n_rung", "n_pred",
          "median_rung", "median_pred", "delta", "range_rung", "range_pred", "measured_spread", "granularity_q",
          "threshold", "status", "predicted_delta", "predicted_resolvable"]
    drows = []
    for (rung, cohort) in keys:
        lv = levers.get(rung)
        if not lv or not lv["predecessor"]:
            continue
        for ax in AXES:
            a, b = G.stats(rung, cohort, ax), G.stats(lv["predecessor"], cohort, ax, rung)
            d = delta(a, b, num(lv.get(PRED_COL[ax])))
            drows.append([lv["arm"], rung, lv["predecessor"], lv["lever"], lv["counterpart"], cohort, ax,
                          lv["phase"] if ax == "lever_phase_s" else "", a["n"], b["n"], fmt(a["median"]), fmt(b["median"]),
                          fmt(d["delta"]), fmt(a["range"]), fmt(b["range"]), fmt(d["measured_spread"]), fmt(d["q"]),
                          fmt(d["threshold"]), d["status"], fmt(d["predicted"]),
                          d["predicted_resolvable"] or ("no prediction" if d["predicted"] is None else "")])
    T["deltas.tsv"] = (dh, drows)

    # 5. pairs.tsv
    prows = []
    stock = stock_rungs(levers)
    cohorts = sorted({c for _, c in keys} | {c for _, _, c in G.e})
    for cohort in cohorts:
        for fam, ax in PAIR_AXES:
            sstar, sb = endpoint_rung(emap, f"S*-{fam}", cohort)
            ostar, ob = endpoint_rung(emap, f"O*-{fam}", cohort)
            st, ot = f"S*-{fam}", f"O*-{fam}"
            plist = [("S vs S*", s, None, "stock rung", sstar, st, sb) for s in stock] + \
                    [("S vs O*", s, None, "stock rung", ostar, ot, ob) for s in stock] + \
                    [("S* vs O*", sstar, st, sb, ostar, ot, ob)]
            for name, src, stag, sbas, tgt, ttag, tbas in plist:
                prows += pair_rows(name, cohort, fam, ax, src, stag, sbas, tgt, ttag, tbas, G)
    T["pairs.tsv"] = (PAIR_HEAD, prows)

    # 6. Law 1 across arms
    T["law1.tsv"] = (["accession", "entries", "arms", "rungs", "reference", "reference_roles", "status", "detail"], l1)
    T["law1-detail.tsv"] = (["accession", "run_id", "node", "arm", "rung", "cohort", "role", "bytes", "sha256",
                             "compared_sha256", "status"], det)
    T["s5-nonpreserving.tsv"] = (["accession", "run_id", "arm", "rung", "cohort", "s5_status", "s5_fallback", "s5_P",
                                  "nproc", "outputs_equal_reference", "status"], s5rows)

    # 7. endpoint decomposition runs: cold and warm rows
    eg = {}
    for r in runs:
        p = r["params"]
        if p["run_kind"] == "endpoint" and not r["exclude"]:
            eg.setdefault((p.get("arm", ""), p["endpoint"], p["rung"], p.get("cohort", ""), p["state"]), []).append(r)
    erows = []
    for k in sorted(eg, key=lambda k: tuple(str(x) for x in k)):
        rs = eg[k]
        metrics = ["wall_s", "billed_usd"] + [f"phase.{n}" for n in sorted({n for r in rs for n in r["phases_run"]})]
        for m in metrics:
            vals = [(r["phases_run"].get(m[6:]), None) if m.startswith("phase.") else (r[m], None) for r in rs]
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
    findings = s5_findings(runs, levers)
    return T, defects, notes, [(r, "; ".join(r["exclude"])) for r in runs if r["exclude"]], findings


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


def summary_md(T, defects, notes, excl, runs, commit, findings):
    L = ["# Ladder tables (generated by scripts/lib/ladder_tables.py)", "",
         f"Generated at {commit or 'unknown commit'}. Do not edit: rerun `make g3-ladder`. Every number is in a table "
         "beside this file; manifest.json lists every input with its sha256.", "",
         f"- Ladder runs found: {len(runs)} ({sum(1 for r in runs if r['params']['run_kind'] == 'ladder')} ladder, "
         f"{sum(1 for r in runs if r['params']['run_kind'] == 'endpoint')} endpoint).",
         f"- Excluded from the attribution: {len(excl)}" + "".join(f"\n  - {r['run_id']}: {why}" for r, why in excl),
         f"- DEFECTs: {len(defects)}" + "".join(f"\n  - {k}: {v}" for k, v in defects[:50]),
         "- Findings against a lever: " + (str(len(findings)) + "".join(f"\n  - {f}" for f in findings) if findings else "none"),
         f"- Notes: {len(notes)}" + "".join(f"\n  - {n}" for n in notes[:50]), "",
         "A delta is resolved only if |delta median| > 2 x max(range of rung, range of predecessor, instrument "
         "granularity q); otherwise it is unresolvable, never a null (deltas.tsv). The median of two runs is their mean. "
         "Effective cost is per resource, never combined (effcost.tsv, runs.tsv).", ""]
    h, rows = T["pairs.tsv"]
    ix = {k: i for i, k in enumerate(h)}
    blocks, cur = [], []
    for r in rows:
        if r[ix["axis"]] not in ("wall_s", "billed_usd"):
            continue
        cur.append(r)
        if r[ix["row"]] == "total":
            blocks.append(cur)
            cur = []
    if blocks:
        L += ["## Pairs (wall_s on the time endpoint, billed_usd on the cost endpoint; every axis is in pairs.tsv)", "",
              "Each total is followed by its per-lever rows (Law 5).", "",
              "| pair | cohort | axis | source | target | endpoint basis | row | rung | delta | status | ratio source/target "
              "| sum of lever deltas | note |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for b in blocks:
            t = b[-1]
            g = lambda r, k: r[ix[k]]
            L.append(f"| {g(t, 'pair')} | {g(t, 'cohort')} | {g(t, 'axis')} | {g(t, 'source')} | {g(t, 'target')} | "
                     f"{g(t, 'endpoint_basis')} | **total** | | {g(t, 'delta')} | {g(t, 'status')} | "
                     f"{g(t, 'ratio_source_over_target')} | {g(t, 'sum_of_lever_deltas')} | {g(t, 'note')} |")
            for r in b[:-1]:
                L.append(f"| | | | | | | lever {g(r, 'step')} | {g(r, 'rung')} ({g(r, 'lever')}) | {g(r, 'delta')} | "
                         f"{g(r, 'status')} | | | |")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", default=os.path.join(ROOT, "results"))
    ap.add_argument("--levers", default=os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"))
    ap.add_argument("--modelled", default=None, help="modelled values (default <results>/g3/ladder-modelled.tsv)")
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "g3", "ladder"))
    ap.add_argument("--spend", default=None, help="campaign spend.tsv (default <results>/g3/campaign/spend.tsv)")
    a = ap.parse_args(argv)
    rd = Reader()
    levers = load_levers(a.levers, rd)
    mpath = a.modelled or os.path.join(a.results, "g3", "ladder-modelled.tsv")
    modelled = load_modelled(mpath, rd)
    runs = discover(a.results, rd)
    spend_p = a.spend or os.path.join(a.results, "g3", "campaign", "spend.tsv")
    cs = None
    if os.path.exists(spend_p):
        cs = {r.get("run") for r in csv.DictReader(rd.text(spend_p).splitlines(), delimiter="\t")}
    T, defects, notes, excl, findings = build(runs, levers, cs, modelled)
    if not levers:
        notes.insert(0, f"no lever table at {os.path.relpath(a.levers, ROOT)}: no predecessors, endpoints, deltas or pairs")
    os.makedirs(a.out, exist_ok=True)
    commit = git("rev-parse", "HEAD")
    outs = []
    for name, (h, rows) in T.items():
        write_tsv(os.path.join(a.out, name), h, rows)
        outs.append(name)
    with open(os.path.join(a.out, "summary.md"), "w") as f:
        f.write(summary_md(T, defects, notes, excl, runs, commit, findings))
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
           "modelled": rel(os.path.abspath(mpath)) if modelled else None,
           "runs": [{"run_id": r["run_id"], "dir": rel(os.path.abspath(r["dir"])), "commit": r["commit"],
                     "params": r["params"]} for r in runs],
           "defects": [f"{k}: {v}" for k, v in defects], "findings": findings, "notes": notes,
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
