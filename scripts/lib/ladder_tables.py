#!/usr/bin/env python3
"""The #25 ladder tables (#52, WP-8; runbook docs/ladder.md, "Ladder tables"). From the record only.

  ladder_tables.py [--results results] [--levers scripts/g3/ladder.levers.tsv]
                   [--modelled results/g3/ladder-modelled.tsv] [--out results/g3/ladder]

Inputs: every ladder run dir under results/<gate>/<yyyymmdd>-* (a single run's manifest.json, or a
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
# A conditional alias_cohorts entry's suffix (ladder_levers.COND), and alias_cohort_checks' prefix for
# one whose two rungs resolve and differ: no alias there, the rung reads its own runs.
ALIAS_COND = "(if same configuration)"
# A selection whose rule leaves only its predecessor (ladder_select.SINGLE: O4b where the in-flight range
# collapses; Scott's ruling 2, 2026-10-13): labelled "single candidate, not measured", never a measured 0.
SINGLE_PREFIX = "single candidate"
SINGLE_LABEL = "single candidate, not measured"
NOT_ALIAS = "no alias here (conditional): "
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
EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # sha256 of an empty stream
GZ_WARNING = 2   # GNU gzip's exit for a warning (e.g. "trailing garbage ignored"): the output is complete
# The run phases ladder.body.sh marks on every run, and those it marks only on some (SETUP=overlap,
# a rapidgzip GUNZIP, sdk-stream).
BODY_PHASES = ("setup", "fetch-db", "etag-hash.k2d", "fetch-inputs", "load", "classify", "upload-drain")
COND_PHASES = ("identity", "build-wait", "sha-get")
# Gross and net (Scott, 2026-10-10, #25): every wall delta and pair is reported gross and net of the
# measurement-only work, net the headline. The tables do not re-derive that work: each node emits one
# `lad-net {"v": 1, "rank", "critical_measurement_s"}` line (#51 computes the number under its rule),
# and net wall = max over nodes of (that node's terminated_at - its critical_measurement_s) - the first
# launch_time.
NET_PARTS = ("identity_s", "sha_get_s", "sha_critical_s")  # lad-net's components; they sum to critical_measurement_s
NET_BASIS = "per node: max over nodes of (terminated_at - lad-net critical_measurement_s) - first launch"
EFF_NET = [(e.replace("_usd", "_net_usd"), e) for e, _ in EFF]
AXES = ["wall_net_s", "wall_s", "billed_net_usd", "billed_usd", "lever_phase_s"]
NET_OF = {"wall_net_s": "wall_s", "billed_net_usd": "billed_usd", **dict(EFF_NET)}
PRED_COL = {"wall_s": "pred_wall_s", "wall_net_s": "pred_wall_s", "billed_usd": "pred_usd", "billed_net_usd": "pred_usd",
            "lever_phase_s": "pred_phase_s"}
PAIR_AXES = [("time", "wall_net_s"), ("time", "wall_s"), ("cost", "billed_net_usd"), ("cost", "billed_usd")] + \
    [x for (en, e) in EFF_NET for x in (("cost", en), ("cost", e))]
SERIES = {"wall_s": "gross", "billed_usd": "gross", "wall_net_s": "net (headline)", "billed_net_usd": "net (prorated; headline)",
          **{e: "gross" for e, _ in EFF}, **{en: "net (prorated)" for en, _ in EFF_NET}, "lever_phase_s": "phase"}


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
        # A rung whose `status` column is `not-run: <reason>` (e.g. S3 when the tune probe chose none):
        # it has no runs; its successor's delta is taken against the nearest run ancestor. Only the
        # status column is read for this.
        st = (f.get("status") or "").strip()
        r["not_run"] = st if st.lower().startswith("not-run") else ""
        # `not_run_cohorts`: the cohorts at which the rung is not run (`c1: <reason>;c10: <reason>`, or a bare
        # `1;10`). There it is treated exactly as `status: not-run`.
        r["not_run_cohorts"] = parse_cohort_list(f.get("not_run_cohorts") or "")
        # A conditional entry (`c100: <reason> (if same configuration)`: O1 where S8 keeps K = 1) holds only
        # where the rung resolves to its run predecessor's configuration; not_run_cond_checks decides it,
        # by the generator's rule, and only then is the cohort added to not_run_cohorts.
        r["not_run_cond"] = {c: w[:-len(ALIAS_COND)].strip() for c, w in r["not_run_cohorts"].items() if w.endswith(ALIAS_COND)}
        for c in r["not_run_cond"]:
            del r["not_run_cohorts"][c]
        # An alias rung (`status: alias: ...` with `alias_of` set) has no runs of its own: its runs are
        # those of the winner named in ladder.resolved.tsv (key alias) for each cohort.
        r["alias_of"] = [x.strip() for x in (f.get("alias_of") or "").split("|") if x.strip()]
        r["alias"] = st.lower().startswith("alias:") and bool(r["alias_of"])
        # `alias_cohorts` (`c1: O0;...`): at those cohorts the rung has another rung's configuration
        # (the cost chain where it coincides with the time chain) and reads that rung's runs. An entry
        # `c1: O3-n2 (if same configuration)` is conditional (`alias_cond`): an alias only where the
        # two resolve to one configuration (alias_cohort_checks decides it, by the generator's rule).
        ac = {c: t.strip() for c, t in parse_cohort_list(f.get("alias_cohorts") or "").items() if t.strip()}
        r["alias_cond"] = {c for c, t in ac.items() if t.endswith(ALIAS_COND)}
        r["alias_cohorts"] = {c: (t[:-len(ALIAS_COND)].strip() if c in r["alias_cond"] else t) for c, t in ac.items()}
        # A host that moves with the lever (the `derived` column's `instance:` clause; the generator
        # honours it only for O3's right-sized candidates and their alias): the delta includes it.
        r["derived_host"] = re.search(r"(?:^|; )instance: ", f.get("derived") or "") is not None
        if not r["arm"]:
            r["arm"] = r["rung"][:1]
        if r["rung"]:
            out[r["rung"]] = r
    return out


def cite_problem(cites, rd, repo):
    """'' if every `path=sha256` of a resolution's cites column names a file under REPO with that
    sha256 (each one read, so it is an input of manifest.json), else the first failure."""
    for c in cites.split():
        p, _, h = c.rpartition("=")
        if not p or not re.fullmatch(r"[0-9a-f]{64}", h) or ".." in p.split("/"):
            return f"cite {c!r} is not path=<sha256>"
        full = os.path.join(repo, p)
        if not os.path.isfile(full):
            return f"cited {p} does not exist"
        rd.text(full)
        got = rd.files[os.path.abspath(full)][1]
        if got != h:
            return f"cited {p} has sha256 {got}, not the cited {h}"
    return ""


def alias_cohort_checks(levers_path, resolved_path, levers):
    """((rung, cohort) -> why the alias_cohorts pair does not verify, or ''), DEFECTs): each
    declaration is checked by the generator's own rule (ladder_levers.alias_state and
    alias_cohort_problems, on the lever table's resolved values under ladder.resolved.tsv's rows)
    before its target's runs are read. An unconditional pair whose configurations differ is a DEFECT
    (levers); one that cannot be resolved is not verified. Either way the rung reads no runs there.
    A conditional pair (`(if same configuration)`) whose configurations differ is no alias there:
    NOT_ALIAS + why, and the rung reads its own runs; one that cannot be resolved is not verified."""
    out, defects = {}, []
    pairs = [(r, c, t) for r, lv in sorted(levers.items()) for c, t in sorted((lv.get("alias_cohorts") or {}).items())]
    if not pairs:
        return out, defects
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import ladder_levers as LL
        rows = LL.load(levers_path)
        res = {}
        if resolved_path and os.path.exists(resolved_path):
            for f in LL.resolved_rows(resolved_path):
                res[(f.get("origin", ""), (f.get("cohort") or "").lstrip("c"), f.get("key", ""))] = (f.get("value", ""), f.get("source", ""))
        names = LL.by_name(rows)
    except (ValueError, OSError, KeyError) as e:
        for r, c, t in pairs:
            out[(r, c)] = f"not verified: the lever table cannot be resolved ({e})"
        return out, defects
    for r, c, t in pairs:
        if c in (levers[r].get("alias_cond") or set()):
            try:
                st, _, why = LL.alias_state(rows, names[r], c, res)
            except (ValueError, KeyError) as e:
                out[(r, c)] = f"not verified: {e}"
                continue
            out[(r, c)] = {"alias": "", "own": NOT_ALIAS + why}.get(st, f"not verified (conditional): {why}")
            continue
        try:
            a, abad = LL._values(rows, names[r], c, res)
            b, bbad = LL._values(rows, names[t], c, res)
        except (ValueError, KeyError) as e:
            out[(r, c)] = f"not verified: {e}"
            continue
        if abad or bbad:
            out[(r, c)] = f"not verified: unresolved at c{c} ({', '.join(abad + bbad)})"
        elif not LL.same_config(a, b):
            diff = [k for k in LL.KEYS + ["instance"] if a[k] != b[k]]
            out[(r, c)] = f"its configuration differs from {t}'s in {','.join(diff)}"
            defects.append(("levers", f"ladder.levers.tsv: {r} at c{c} is declared an alias of {t} (alias_cohorts), but their "
                                      f"configurations differ in {','.join(diff)}"))
        else:
            out[(r, c)] = ""
    return out, defects


def not_run_cond_checks(levers_path, resolved_path, levers, cohorts=None):
    """Decide each conditional not_run_cohorts entry by the generator's rule (ladder_levers.notrun_state,
    on the lever table's values resolved under ladder.resolved.tsv's rows). Where it holds, the cohort is
    added to the rung's not_run_cohorts (the tables then skip it, as for any not-run rung); notes for
    the entries that hold and those that cannot be decided (the rung is then read as run there).
    COHORTS, when given, limits the notes to the cohorts the record has."""
    todo = [(r, c) for r, lv in sorted(levers.items()) for c in sorted(lv.get("not_run_cond") or {})]
    notes = []
    if not todo:
        return notes
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import ladder_levers as LL
        rows = LL.load(levers_path)
        res = {}
        if resolved_path and os.path.exists(resolved_path):
            for f in LL.resolved_rows(resolved_path):
                res[(f.get("origin", ""), (f.get("cohort") or "").lstrip("c"), f.get("key", ""))] = (f.get("value", ""), f.get("source", ""))
        names = LL.by_name(rows)
    except (ValueError, OSError, KeyError) as e:
        return [f"conditional not_run_cohorts entries not decided: the lever table cannot be resolved ({e})"]
    for r, c in todo:
        try:
            st, why = LL.notrun_state(rows, names[r], c, res)
        except (ValueError, KeyError) as e:
            st, why = "undecided", str(e)
        if st == "not-run":
            levers[r]["not_run_cohorts"][c] = f"{levers[r]['not_run_cond'][c]} (conditional: it holds)"
            if cohorts is None or c in cohorts:
                notes.append(f"{r} at c{c}: {why}")
        elif st == "undecided" and (cohorts is None or c in cohorts):
            notes.append(f"{r} at c{c}: conditional not_run_cohorts entry undecided ({why}): read as run there")
    return notes


def pair_alias(levers, pair_checks, rung, cohort):
    """The rung RUNG's alias_cohorts entry names at COHORT, or '' where it has none or where a
    conditional entry is no alias (alias_cohort_checks: NOT_ALIAS)."""
    t = ((levers.get(rung) or {}).get("alias_cohorts") or {}).get(cohort)
    if t and (pair_checks or {}).get((rung, cohort), "").startswith(NOT_ALIAS):
        return ""
    return t or ""


def load_resolved(path, rd, levers, repo=ROOT):
    """((alias rung, cohort) -> (winner or None, note), errors), from ladder.resolved.tsv rows with
    key `alias` (columns origin, cohort, key, value, source, and cites when make ladder-select wrote
    the row). A winner outside the rung's alias_of and a duplicated (rung, cohort) are errors
    (DEFECTs), and leave the alias unresolved there. A row whose cites do not verify (a file under
    REPO missing or changed) leaves the alias unresolved, with that note. Missing file: ({}, [])."""
    out, errs = {}, []
    if not path or not os.path.exists(path):
        return out, errs
    lines = [ln for ln in rd.text(path).splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    for f in csv.DictReader(lines, delimiter="\t"):
        if (f.get("key") or "").strip() != "alias":
            continue
        rung, c, v = (f.get("origin") or "").strip(), (f.get("cohort") or "").strip().lstrip("c"), (f.get("value") or "").strip()
        lv = levers.get(rung)
        if not c.isdigit() or not lv or not lv.get("alias"):
            continue
        k = (rung, int(c))
        if k in out:
            errs.append(f"ladder.resolved.tsv: {rung} at c{c} resolved more than once")
            out[k] = (None, f"alias unresolved: {rung} at c{c} has more than one ladder.resolved.tsv row")
        elif v not in lv["alias_of"]:
            errs.append(f"ladder.resolved.tsv: {rung} at c{c} names {v!r}, not one of its alias_of {'|'.join(lv['alias_of'])}")
            out[k] = (None, f"alias unresolved: ladder.resolved.tsv names {v!r}, not one of {'|'.join(lv['alias_of'])}")
        elif cite_problem(f.get("cites") or "", rd, repo):
            out[k] = (None, f"alias unresolved: ladder.resolved.tsv's {rung} c{c} row ({v}) cites do not verify: "
                            f"{cite_problem(f.get('cites') or '', rd, repo)}")
        else:
            mg = (f.get("margin") or "").strip()
            single = f"; {mg}" if mg.startswith(SINGLE_PREFIX) else ""
            out[k] = (v, f"alias of {v} (ladder.resolved.tsv; source {f.get('source') or '-'}{single})")
    return out, errs


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


def parse_cohort_list(v):
    """`c1: reason;c10: reason` or `1;10` -> {cohort: reason}. A `;` inside a reason stays with it."""
    out, last = {}, None
    for part in str(v).split(";"):
        m = re.match(r"^\s*c?(\d+)\s*(?::\s*(.*))?$", part)
        if m:
            last = int(m.group(1))
            out[last] = (m.group(2) or "").strip()
        elif last is not None and part.strip():
            out[last] = f"{out[last]};{part}".strip()
    return out


def not_run(lv, cohort=None):
    """The reason a rung is not run (at this cohort), or "": `status: not-run`, or the cohort listed in
    `not_run_cohorts`."""
    if not lv:
        return ""
    if lv.get("not_run"):
        return lv["not_run"]
    if cohort is not None and cohort in (lv.get("not_run_cohorts") or {}):
        why = lv["not_run_cohorts"][cohort]
        return f"not-run at c{cohort}" + (f": {why}" if why else "") + " (not_run_cohorts)"
    return ""


def run_pred(levers, rung, cohort=None):
    """(the nearest ancestor that is run (at this cohort), [the skipped not-run rungs])."""
    p, skipped = (levers.get(rung) or {}).get("predecessor", ""), []
    while p and not_run(levers.get(p), cohort) and p not in skipped:
        skipped.append(p)
        p = levers[p].get("predecessor", "")
    return p, skipped


def pred_basis(levers, rung, cohort=None):
    p, skipped = run_pred(levers, rung, cohort)
    if not skipped:
        return "direct"
    return f"nearest run ancestor {p or '-'} (" + "; ".join(f"{x} {not_run(levers[x], cohort)}" for x in skipped) + ")"


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


def check_source(source, repo):
    """A modelled row's source is `<generator text> | path=sha256 path=sha256 ...` (paths relative
    to the repo root). It is checkable only if it names at least one file and every file exists
    with that sha256. Returns (ok, reason)."""
    if "|" not in source:
        return False, "no `| path=sha256 ...` list"
    pairs = source.split("|", 1)[1].split()
    if not pairs:
        return False, "no files cited"
    for p in pairs:
        if "=" not in p:
            return False, f"{p!r} is not path=sha256"
        rel, sha = p.rsplit("=", 1)
        f = os.path.join(repo, rel)
        if not os.path.isfile(f):
            return False, f"{rel} does not exist"
        with open(f, "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != sha:
                return False, f"{rel} sha256 is not {sha[:12]}..."
    return True, ""


MODEL_COLS = ("arm", "rung", "cohort", "axis", "value", "basis", "from_cohort", "target_ref", "runs", "source")


def load_modelled(path, rd, repo, results, levers_path):
    """(rung, cohort, axis) -> {value, basis, source}, and the refused rows. The file is written by
    make g3-ladder-model (ladder_model.py). Every row is re-derived: its cited files must check
    (check_source), and ladder_model.model() on the current record, with the row's own rung,
    from_cohort, cohort and target_ref, must give the same value from exactly the same runs.
    Anything else (a hand-entered row, an edited value, a stale model) is refused. Missing file: {}."""
    if not path or not os.path.exists(path):
        return {}, []
    import ladder_model  # noqa: E402 (ladder_model imports this module)
    out, refused, cache = {}, [], {}
    lines = [ln for ln in rd.text(path).splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    for i, f in enumerate(csv.DictReader(lines, delimiter="\t"), 2):
        where = f"{os.path.basename(path)} row {i} ({f.get('rung')} c{f.get('cohort')} {f.get('axis')})"
        miss = [k for k in MODEL_COLS if not (f.get(k) or "").strip()]
        v, c, fc = num(f.get("value")), (f.get("cohort") or ""), (f.get("from_cohort") or "")
        if miss or v is None or not c.isdigit() or not fc.isdigit():
            refused.append(f"{where}: not a g3-ladder-model row (missing or non-numeric: {', '.join(miss) or 'value/cohort'})")
            continue
        ok, why = check_source(f.get("source", ""), repo)
        if not ok:
            refused.append(f"{where}: source not checkable: {why}")
            continue
        key = (f["rung"], int(fc), int(c), f["target_ref"])
        if key not in cache:
            try:
                cache[key] = ladder_model.model(results, levers_path, key[0], key[1], key[2], key[3])
            except SystemExit as e:
                cache[key] = ([], str(e))
        rows, msg = cache[key]
        got = {r[3]: r for r in rows}.get(f["axis"])
        if got is None:
            refused.append(f"{where}: the model does not reproduce it on the current record ({msg})")
            continue
        want_runs = set(got[8].split(","))
        if set(f["runs"].split(",")) != want_runs:
            refused.append(f"{where}: cites runs {f['runs']} but the model would use {got[8]} now (stale or edited)")
            continue
        if abs(float(got[4]) - v) > 1e-6 * max(1.0, abs(v)):
            refused.append(f"{where}: value {f['value']} but the model gives {got[4]} on the current record")
            continue
        out[(f["rung"], int(c), f["axis"])] = {"value": v, "basis": f.get("basis", "modelled"), "source": f["source"]}
    return out, refused


# ---------------------------------------------------------------- one run
def lad_lines(member_dir, rd, notes, label, tag="lad-sample", fname="lad-samples.jsonl", kind=None):
    """The objects of one kind of lad line on a node: the pushed file (filtered to `kind`, when the
    file holds several kinds), checked against the `<tag> {json}` lines streamed into log/run.log."""
    pushed, streamed = [], []
    for p in sorted(glob.glob(os.path.join(member_dir, "out", "**", fname), recursive=True)):
        for i, ln in enumerate(rd.text(p).splitlines()):
            if ln.strip():
                try:
                    o = json.loads(ln)
                    if kind is None or (isinstance(o, dict) and o.get("kind") == kind):
                        pushed.append(o)
                except ValueError:
                    notes.append(f"{label}: {os.path.relpath(p, member_dir)} line {i + 1} is not JSON")
    log = os.path.join(member_dir, "log", "run.log")
    if os.path.exists(log):
        dec = json.JSONDecoder()
        for ln in rd.text(log).splitlines():
            k = ln.find(tag + " {")
            if k < 0:
                continue
            try:
                streamed.append(dec.raw_decode(ln[k + len(tag) + 1:])[0])
            except ValueError:
                notes.append(f"{label}: a streamed {tag} line is not JSON (cut off?)")
    key = lambda o: json.dumps(o, sort_keys=True)
    if pushed and streamed and sorted(map(key, pushed)) != sorted(map(key, streamed)):
        notes.append(f"{label}: streamed {tag} lines ({len(streamed)}) differ from the pushed file ({len(pushed)}); "
                     "the pushed file is used")
    if pushed:
        return pushed
    if streamed:
        notes.append(f"{label}: no pushed {fname}; lines taken from the streamed log")
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
    if isinstance(ref, str):
        ref = {"ref": ref}
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
        ranks = {members[0][0]: (man.get("cohort") or {}).get("rank", 0)}
        kind, commit, gate = "single", man.get("commit"), man.get("gate")
    elif os.path.exists(cp):
        coh = rd.json(cp)
        members, missing, ranks = [], [], {}
        for m in coh.get("members", []):
            rid = m.get("run_id")
            md = os.path.join(os.path.dirname(d), rid) if rid else None
            if md and m.get("manifest") != "missing" and os.path.exists(os.path.join(md, "manifest.json")):
                members.append((rid, md, rd.json(os.path.join(md, "manifest.json"))))
                ranks[rid] = m.get("rank")
            else:
                missing.append(f"rank {m.get('rank')}" + (f" ({rid})" if rid else ""))
        want = coh.get("nodes") if is_int(coh.get("nodes")) else len(coh.get("members", []))
        if want > len(coh.get("members", [])):
            missing.append(f"{want - len(coh.get('members', []))} member(s) absent from cohort.json (nodes {want})")
        params = norm_params(coh.get("params")) or (norm_params(members[0][2].get("params")) if members else None)
        if not params:
            return None
        kind, commit, gate = "cohort", coh.get("commit"), coh.get("gate")
    else:
        return None
    run = {"run_id": os.path.basename(os.path.normpath(d)), "dir": d, "kind": kind, "gate": gate, "commit": commit,
           "params": params, "notes": notes, "nodes": len(members), "exclude": [],
           "missing_members": missing if kind == "cohort" else []}
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
    if kind == "single":
        run["planned"], run["planned_basis"] = planned_set(m0, results, rd, notes), "manifest"
    else:
        # The cohort's own record (cohort.json sample_accessions_ref, or a sample_accessions list),
        # never the union of the members that happened to write a manifest.
        run["planned"], run["planned_basis"] = planned_set(coh, results, rd, notes), "cohort.json"
        if run["planned"] is None and not coh.get("sample_accessions_ref") and members:
            # A literal list is not in cohort.json; every member got the same spec env.
            run["planned"], run["planned_basis"] = planned_set(m0, results, rd, notes), f"{members[0][0]} manifest (literal list)"
    samples = []
    for rid, md, _ in members:
        for o in lad_lines(md, rd, notes, rid):
            o = dict(o)
            o["_node"] = rid
            samples.append(o)
    run["samples"] = samples
    run["nodes_info"] = [{"rid": rid, "rank": ranks.get(rid), "launch": ts((m.get("instance") or {}).get("launch_time")),
                          "term": ts((m.get("instance") or {}).get("terminated_at")),
                          "lad_net": lad_lines(md, rd, notes, rid, "lad-net", "lad-net.jsonl")} for rid, md, m in members]
    # The body's S5 identity lines (lad-identity, kind identity, in out/lad.jsonl): each input's verdict and
    # its input_defect flag (GNU gzip failed or gave an empty stream).
    run["identity"] = [dict(o, _node=rid) for rid, md, _ in members
                       for o in lad_lines(md, rd, notes, rid, "lad-identity", "lad.jsonl", kind="identity")]
    net_components(run)
    u = read_util(d, rd)
    run["util"] = u
    run["util_coverage"] = "missing (no tables/util.tsv fleet row)" if u is None else (u.get("coverage") or "full")
    run["eff"] = {}
    for e, uk in EFF:
        uv, c = (None, None) if u is None else (u.get(uk), u.get("cost_usd"))
        run["eff"][e] = None if uv is None or c is None else (float("inf") if uv == 0 else c / uv)
    return run


def lad_net_errors(run):
    """The lad-net contract: exactly one line per node, {"v": 1, "rank": the node's rank,
    "critical_measurement_s": seconds >= 0}. A missing line is not an error here (net is then
    missing, with a note); a malformed or duplicated one is."""
    errs = []
    for n in run.get("nodes_info", []):
        L = n["lad_net"]
        where = f"{run['run_id']} {n['rid']}: lad-net"
        if len(L) > 1:
            errs.append(f"{where}: {len(L)} lines (one per node)")
        for x in L:
            c = x.get("critical_measurement_s") if isinstance(x, dict) else None
            if not isinstance(x, dict) or not (is_int(x.get("v")) and x["v"] == CONTRACT_V):
                errs.append(f"{where}: v must be {CONTRACT_V}")
            elif not is_int(x.get("rank")) or x["rank"] != n["rank"]:
                errs.append(f"{where}: rank {x.get('rank')!r} is not the node's rank {n['rank']!r}")
            elif not (isinstance(c, (int, float)) and not isinstance(c, bool) and c >= 0):
                errs.append(f"{where}: critical_measurement_s {c!r} is not seconds >= 0")
            elif any(k in x for k in NET_PARTS) and not all(
                    isinstance(x.get(k), (int, float)) and not isinstance(x.get(k), bool) and x[k] >= 0 for k in NET_PARTS):
                errs.append(f"{where}: {', '.join(NET_PARTS)} must all be seconds >= 0 when any is given")
            elif all(k in x for k in NET_PARTS) and abs(sum(x[k] for k in NET_PARTS) - c) > 0.001:
                errs.append(f"{where}: {' + '.join(NET_PARTS)} = {sum(x[k] for k in NET_PARTS):.3f} is not "
                            f"critical_measurement_s {c:.3f} (within 1 ms)")
            elif n["launch"] is not None and n["term"] is not None and c > n["term"] - n["launch"]:
                errs.append(f"{where}: critical_measurement_s {c:.3f} exceeds the node's window "
                            f"{n['term'] - n['launch']:.3f} s (terminated_at - launch_time)")
    return errs


def net_components(run):
    """Net wall (Scott, 2026-10-10; the per-node rule pending #51's final definition): the max over
    nodes of (terminated_at - critical_measurement_s from that node's lad-net line), minus the first
    launch_time. Missing (never imputed) if any node lacks a valid lad-net line or its timestamps.
    Net billed and net effective cost are prorated, x net/gross."""
    info = run.get("nodes_info", [])
    crit, ends, why = {}, [], []
    for n in info:
        L = [x for x in n["lad_net"] if isinstance(x, dict)]
        c = L[-1].get("critical_measurement_s") if len(L) == 1 else None
        if len(L) != 1 or not (isinstance(c, (int, float)) and not isinstance(c, bool) and c >= 0):
            why.append(f"rank {n['rank']}: {'no lad-net line' if not L else 'no valid lad-net line'}")
            continue
        crit[n["rank"]] = c
        if n["term"] is None:
            why.append(f"rank {n['rank']}: no terminated_at")
            continue
        ends.append(n["term"] - c)
    launches = [n["launch"] for n in info]
    run["net"] = {"critical": crit, "basis": NET_BASIS}
    if why or not ends or None in launches:
        run["wall_net_s"] = None
        if info:
            run["notes"].append("net missing (not imputed): " + "; ".join(why or ["no launch_time"]))
    else:
        run["wall_net_s"] = max(ends) - min(launches)
        if run["wall_net_s"] < 0:
            run["notes"].append(f"net wall {run['wall_net_s']:.3f} s < 0")
    w = run["wall_s"]
    run["net_ratio"] = None if not w or run["wall_net_s"] is None else run["wall_net_s"] / w
    run["billed_net_usd"] = None if run["billed_usd"] is None or run["net_ratio"] is None else run["billed_usd"] * run["net_ratio"]


def discover(results, rd):
    runs = []
    for d in sorted(glob.glob(os.path.join(results, "*", "[0-9]" * 8 + "-[0-9]*"))):   # run ids: <yyyymmdd>-<hhmmss>-..., any year
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
    for k in ("v", "arm", "rung", "cohort", "accession", "pairs", "rc", "t_start", "t_end", "phases", "outputs", "s5"):
        if k not in s:
            errs.append(f"{where}: missing {k}")
    if "t_start" in s and "t_end" in s and not (isinstance(s["t_start"], (int, float)) and isinstance(s["t_end"], (int, float))
                                               and not isinstance(s["t_start"], bool) and s["t_end"] >= s["t_start"]):
        errs.append(f"{where}: t_start and t_end must be epoch seconds with t_end >= t_start")
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
        elif s5.get("status") == "differs" and s5.get("fallback", "none") != "gzip":
            errs.append(f"{where}: s5.status differs needs s5.fallback gzip (the body falls back to gzip on that input)")
        elif s5.get("status") != "n/a":
            rg, gz, rx, gx = s5.get("rg_sha256"), s5.get("gz_sha256"), s5.get("rg_exit"), s5.get("gz_exit")
            if not (sha_list(rg) and sha_list(gz) and len(rg) == len(gz)):
                errs.append(f"{where}: s5.rg_sha256 and s5.gz_sha256 must be equal-length lists of 64-hex sha256 "
                            "(one per input file, mate order)")
            elif not (isinstance(rx, list) and isinstance(gx, list) and len(rx) == len(rg) == len(gx)
                      and all(is_int(x) for x in rx + gx)):
                errs.append(f"{where}: s5.rg_exit and s5.gz_exit must be integer lists, one per mate")
            elif "gz_warning" in s5 and s5["gz_warning"] != [x == GZ_WARNING for x in gx]:
                errs.append(f"{where}: s5.gz_warning {s5['gz_warning']!r} must be, per mate, whether gz_exit is {GZ_WARNING} ({gx})")
            else:
                # The body's B1 rule: a mate differs if the sha256 differ, rapidgzip exits non-zero, GNU
                # gzip exits other than 0 or 2 (2 is its warning, e.g. trailing garbage ignored, with the
                # output complete), or either output is the empty stream.
                differs = rg != gz or any(x != 0 for x in rx) or any(x not in (0, GZ_WARNING) for x in gx) or EMPTY_SHA in rg + gz
                if s5.get("status") == "identical" and differs:
                    errs.append(f"{where}: s5.status identical, but the B1 rule says differs (sha256 lists, a non-zero "
                                "rapidgzip exit, a gzip exit other than 0 or 2, or an empty-stream sha256)")
                elif s5.get("status") == "differs" and not differs:
                    errs.append(f"{where}: s5.status differs, but the lists are equal, rapidgzip exits 0, gzip 0 or 2, and no output is empty")
    return errs


def gz_warned(s):
    """The mates (R1, R2, ...) on which GNU gzip exited 2, its warning, in the identity phase; [] if none."""
    x = s.get("s5") if isinstance(s.get("s5"), dict) else {}
    if x.get("status") in (None, "n/a") or not isinstance(x.get("gz_exit"), list):
        return []
    return [f"R{i + 1}" for i, e in enumerate(x["gz_exit"]) if e == GZ_WARNING]


def gzip_failed(s):
    """The reason, if the identity phase's gzip run failed on this input (a gz_exit other than 0 or 2,
    or an empty gzip stream); "" otherwise. Exit 2 is GNU gzip's warning (e.g. trailing garbage
    ignored): its output is complete and upstream's wrapper ignores the status, so it is no failure."""
    x = s.get("s5") if isinstance(s.get("s5"), dict) else {}
    if x.get("status") in (None, "n/a"):
        return ""
    why = []
    if any(e not in (0, GZ_WARNING) for e in x.get("gz_exit") or []):
        why.append(f"gzip exited {x.get('gz_exit')}")
    if EMPTY_SHA in (x.get("gz_sha256") or []):
        why.append("gzip's output is the empty stream")
    return ("input or staging failure: " + " and ".join(why)) if why else ""


def sha_list(v):
    return isinstance(v, list) and v and all(isinstance(x, str) and HEX64.match(x) for x in v)


def contract_errors(run):
    errs = []
    for s in run["samples"]:
        errs += sample_errors(run, s)
    return errs


def s5_of(s):
    x = s.get("s5") if isinstance(s.get("s5"), dict) else {}
    return x.get("status"), x.get("fallback", "none")


RECORDED_CLASSES = ("contract", "incomplete")   # the checks a recorded defect's run does not re-raise


def load_recorded(path, rd=None):
    """run id -> class (the text before the first ':' of the class column, e.g. capacity, defect,
    partial) from scripts/lib/g3_defects.tsv, the record of runs already judged defective (capacity
    refusals, failed launches). Missing file: {}."""
    if not path or not os.path.exists(path):
        return {}
    text = rd.text(path) if rd is not None else open(path).read()
    out = {}
    for f in csv.DictReader([ln for ln in text.splitlines() if ln.strip() and not ln.startswith("#")], delimiter="\t"):
        rid = (f.get("run") or "").strip()
        if rid:
            out[rid] = ((f.get("class") or "").split(":", 1)[0].strip() or "recorded")
    return out


def recorded_class(r, recorded):
    """The recorded-defect class of run R (by its run id), or ''."""
    return (recorded or {}).get(r["run_id"], "")


def validate(runs, levers, defects, recorded=None):
    """Contract, failed samples and completeness. Each DEFECT also excludes its run. A run recorded in
    scripts/lib/g3_defects.tsv (RECORDED: run id -> class) is excluded once, as "recorded defect
    (<class>): excluded", and its contract and incomplete checks raise no DEFECT (they are what the
    record already says). Its other checks still raise theirs, and Law 1 (law1) is never suppressed."""
    all_defects = defects
    for r in runs:
        rid = r["run_id"]
        rc = recorded_class(r, recorded)
        if rc == "capacity" and r["samples"]:
            # A capacity refusal launches nothing, so it has no sample records. One that has them is not
            # what the record says: nothing is suppressed, and the note says why.
            r["exclude"].append(f"recorded defect (capacity) with {len(r['samples'])} sample record(s): not a refused launch, "
                                f"so its DEFECTs are raised")
            all_defects.append(("recorded", f"{rid}: recorded as capacity in g3_defects.tsv, but it has "
                                            f"{len(r['samples'])} sample record(s)"))
            rc = ""
        if rc:
            r["exclude"].append(f"recorded defect ({rc}): excluded")
            defects = _RecordedSink(all_defects, r)
        else:
            defects = all_defects
        if r["missing_members"]:
            e = f"cohort member manifest missing: {', '.join(r['missing_members'])}"
            defects.append(("incomplete", f"{rid}: {e}"))
            r["exclude"].append(f"DEFECT (incomplete): {e}")
        for e in params_errors(r["params"], levers):
            defects.append(("contract", f"{rid}: {e}"))
            r["exclude"].append(f"DEFECT (contract): {e}")
        for e in lad_net_errors(r):
            defects.append(("contract", e))
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
        # gzip itself failed or gave an empty stream: an input or staging failure, not an S5 finding. From the
        # sample's own s5 (gz_exit, gz_sha256), else from the body's identity line (input_defect: true).
        flagged = {}
        for s in r["samples"]:
            if id(s) not in bad and gzip_failed(s):
                flagged.setdefault(str(s["accession"]), gzip_failed(s))
        for x in r.get("identity", []):
            if isinstance(x, dict) and x.get("input_defect") is True:
                acc = str(x.get("sample") or x.get("file") or "?")
                flagged.setdefault(acc, f"input or staging failure: the identity line flags input_defect on {x.get('file', '?')} "
                                        f"(gzip exit {x.get('gzip_exit')!r})")
        for acc, why in sorted(flagged.items()):
            e = f"{acc}: {why}"
            defects.append(("input", f"{rid} {e}"))
            r["exclude"].append(f"DEFECT (input): {e}")
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
        # The run's own lever phase: a term that matches nothing is a contract DEFECT, never a silently
        # missing value. A run successor's phase (its delta is taken against this run) that this run
        # lacks is a DEFECT too when the body marks that phase on every run (BODY_PHASES); only a
        # conditional phase (COND_PHASES: identity, build-wait, sha-get), which the successor's own
        # lever may be what adds, is a note.
        rung, coh = r["params"]["rung"], r["params"].get("cohort")
        spec = (levers.get(rung) or {}).get("phase")
        miss = phase_missing(r, spec) if spec else []
        if miss:
            e = f"its lever phase {spec}: {', '.join(miss)} match(es) no manifest phase or lad-sample phase"
            defects.append(("contract", f"{rid}: {e}"))
            r["exclude"].append(f"DEFECT (contract): {e}")
        for x, lv in sorted(levers.items()):
            if not lv.get("phase") or not_run(lv, coh) or run_pred(levers, x, coh)[0] != rung:
                continue
            sm = phase_missing(r, lv["phase"])
            cond = [t for t in sm if t.split(":")[-1] in COND_PHASES]
            hard = [t for t in sm if t not in cond]
            if hard:
                e = (f"{x}'s lever phase {lv['phase']}: {', '.join(hard)} not in this run (its predecessor run), "
                     "though the body marks it on every run")
                defects.append(("contract", f"{rid}: {e}"))
                r["exclude"].append(f"DEFECT (contract): {e}")
            if cond:
                r["notes"].append(f"{x}'s lever phase {lv['phase']}: {', '.join(cond)} not in this run (its predecessor run; "
                                  f"a conditional phase), so that delta's phase axis is missing here")
        if r["params"]["rung"] not in levers:
            r["notes"].append(f"rung {r['params']['rung']} is not in ladder.levers.tsv")
        elif not_run(levers[r["params"]["rung"]], r["params"].get("cohort")):
            r["notes"].append(f"rung {r['params']['rung']} is marked {not_run(levers[r['params']['rung']], r['params'].get('cohort'))!r} "
                              "in ladder.levers.tsv")
        if rc:
            # The recorded exclusion stands for the suppressed checks: only it and any unsuppressed DEFECT remain.
            r["exclude"] = [x for x in r["exclude"] if not any(x.startswith(f"DEFECT ({c})") for c in RECORDED_CLASSES)]
        r["exclude"] = list(dict.fromkeys(r["exclude"]))


# ---------------------------------------------------------------- axes, stats, deltas
def phase_parts(spec):
    """A lever phase's terms, each with its own scope: "run:A+run:B" (as ladder.levers.tsv writes a
    compound phase), "sample:A+run:B" and bare terms alike -> [(scope, name), ...]."""
    out = []
    for t in (spec or "").split("+"):
        t = t.strip()
        if not t:
            continue
        scope, name = t.split(":", 1) if ":" in t else ("", t)
        out.append((scope, name))
    return out


def phase_missing(run, spec):
    """The terms of SPEC that match nothing in RUN: a run: term that is not a manifest phase, a
    sample: term that no lad-sample has, a bare term that is neither."""
    miss = []
    for scope, part in phase_parts(spec):
        in_run = part in run.get("phases_run", {})
        in_sam = any(isinstance(s.get("phases"), dict) and part in s["phases"] for s in run.get("samples", []))
        if (scope == "run" and not in_run) or (scope == "sample" and not in_sam) or (scope == "" and not (in_run or in_sam)) \
                or scope not in ("run", "sample", ""):
            miss.append(f"{scope}:{part}" if scope else part)
    return miss


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
    if axis == "wall_net_s":
        return run["wall_net_s"], Q_WALL + Q_SAMPLE_PHASE  # the timestamps, plus critical_measurement_s at ms
    if axis == "billed_net_usd":
        return run["billed_net_usd"], q_billed(run)
    if axis in NET_OF and axis.startswith("eff_"):
        v, q = axis_value(run, NET_OF[axis], levers, phase_rung)
        r = run["net_ratio"]
        return (None if v is None or r is None else v * r), q
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
    if "alias unresolved" in (a["basis"], b["basis"]):
        d["status"] = "alias unresolved"
        return d
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

    def __init__(self, runs, levers, modelled, emap, notes, resolved=None, pair_checks=None):
        self.levers, self.modelled, self.resolved = levers, modelled, resolved or {}
        # (rung, cohort) -> '' when its alias_cohorts pair verified, else why not (alias_cohort_checks).
        self.pair_checks = pair_checks or {}
        self.g, self.e = {}, {}
        for r in runs:
            if r["exclude"]:
                continue
            p = r["params"]
            if p["run_kind"] == "ladder":
                self.g.setdefault((p["rung"], p["cohort"]), []).append(r)
            elif p["state"] == "cold":
                for t in split_tags(p["endpoint"]):
                    want, _ = endpoint_rung(emap, t, p["cohort"])
                    if want != p["rung"]:
                        notes.append(f"{r['run_id']}: cold endpoint run for {t} at c{p['cohort']} is on {p['rung']}, but "
                                     f"ladder.levers.tsv declares {want or 'no rung'}: not used for the {t} total")
                        continue
                    self.e.setdefault((t, p["rung"], p["cohort"]), []).append(r)
        for (rung, cohort, axis) in sorted(modelled, key=str):
            if any(axis_value(r, axis, levers, rung)[0] is not None for r in self.runs(rung, cohort)):
                notes.append(f"modelled {rung} c{cohort} {axis} ignored: measured runs exist")

    def alias(self, rung, cohort):
        """(the rung whose runs RUNG reads at COHORT, note), or (None, why) if an alias on the way is
        unresolved. In turn: an `alias_cohorts` entry at the cohort gives its target ("alias: same
        configuration as <rung> at c<C>"); an alias rung gives its ladder.resolved.tsv winner; a
        winner or target not run at the cohort (an alias's own predecessor as its candidate) gives its
        nearest run ancestor. Any other rung reads its own runs, (rung, "")."""
        r, notes, seen = rung, [], []
        while True:
            lv = self.levers.get(r) or {}
            if r in seen:
                return None, "alias unresolved: a loop through " + " -> ".join(seen + [r])
            seen.append(r)
            if pair_alias(self.levers, self.pair_checks, r, cohort):
                t = lv["alias_cohorts"][cohort]
                why = self.pair_checks.get((r, cohort), "not verified")
                if why:
                    return None, f"alias unresolved: {r}'s alias_cohorts pair with {t} at c{cohort} does not verify: {why}"
                cond = ", conditional: it holds" if cohort in (lv.get("alias_cond") or set()) else ""
                notes.append(f"alias: same configuration as {t} at c{cohort} (alias_cohorts{cond})")
                r = t
                continue
            if lv.get("alias"):
                w, note = self.resolved.get((r, cohort), (None, "alias unresolved: no ladder.resolved.tsv row (key alias)"))
                if w is None:
                    return None, note
                notes.append(note)
                r = w
                continue
            if r != rung and not_run(lv, cohort):
                p, _ = run_pred(self.levers, r, cohort)
                notes.append(f"{r} {not_run(lv, cohort)}: its run ancestor {p or '-'}'s runs")
                r = p
                continue
            return r, "; ".join(notes)

    def runs(self, rung, cohort):
        w, _ = self.alias(rung, cohort)
        return self.g.get((w, cohort), []) if w else []

    def stats(self, rung, cohort, axis, phase_rung=None):
        w, note = self.alias(rung, cohort)
        if w is None:
            return {"n": 0, "median": None, "min": None, "max": None, "range": None, "q": None,
                    "basis": "alias unresolved", "basis_note": note}
        s = stats([axis_value(r, axis, self.levers, phase_rung or rung) for r in self.runs(rung, cohort)])
        if note:
            s["basis_note"] = note
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


def net_basis(runs):
    return " | ".join(sorted({r["net"]["basis"] for r in runs}))


RIGHTSIZE_NOTE = ("the delta includes the per-N host right-sizing (each N on its family's smallest type that holds "
                  "table/N: vCPUs, memory and network change with N)")


def rightsize_note(G, rung, cohort):
    """RIGHTSIZE_NOTE for a rung whose host moves with its lever (O3 and its candidates, on the runs
    it reads at the cohort), else ''."""
    w, _ = G.alias(rung, cohort)
    return RIGHTSIZE_NOTE if any((G.levers.get(x) or {}).get("derived_host") for x in (rung, w) if x) else ""


def alias_step(G, rung, cohort):
    """For an alias rung: (skip, note). Skip when its winner is its own run predecessor (the alias
    then adds no lever: its runs are the predecessor's)."""
    lv = G.levers.get(rung) or {}
    if not (lv.get("alias") or pair_alias(G.levers, G.pair_checks, rung, cohort)):
        return False, ""
    w, note = G.alias(rung, cohort)
    if w is None:
        return False, note
    pr, _ = run_pred(G.levers, rung, cohort)
    pw, _ = G.alias(pr, cohort) if pr else (None, "")
    if w == pr or (pw is not None and w == pw):
        if lv.get("alias") and SINGLE_PREFIX in (G.resolved.get((rung, cohort), (None, ""))[1] or ""):
            # Ruling 2: its rule left only the predecessor, so nothing was measured: a label, not a 0.
            return True, (f"{rung}: {SINGLE_LABEL} (its rule leaves only its predecessor {pr} at c{cohort}): no lever, "
                          f"no delta")
        return True, f"{rung} is an alias of its predecessor {pr}" + (f" ({pw}'s runs)" if pw not in (None, pr) else "") + ": no lever"
    return False, note


# ---------------------------------------------------------------- the tables
PAIR_HEAD = ["pair", "cohort", "endpoint_axis", "axis", "series", "source", "target", "endpoint_basis", "row", "step", "rung",
             "predecessor", "lever", "n_rung", "n_pred", "delta", "status", "granularity_q", "threshold",
             "source_median", "target_median", "ratio_source_over_target", "sum_of_lever_deltas",
             "residual_total_minus_sum", "util_coverage", "net_basis", "note"]


def pair_rows(name, cohort, fam, ax, src, src_tag, src_basis, tgt, tgt_tag, tgt_basis, G):
    """One pair on one axis: its lever rows (the rung deltas along tgt's predecessor chain back to
    src) and its total row, beside each other (Law 5). An endpoint's total comes from its cold
    endpoint runs where they exist, else from its ladder rung's runs."""
    levers = G.levers
    basis = f"source {src or '-'}: {src_basis}; target {tgt or '-'}: {tgt_basis}"
    base = {"pair": name, "cohort": cohort, "endpoint_axis": fam, "axis": ax, "series": SERIES.get(ax, ""),
            "source": src or "", "target": tgt or "", "endpoint_basis": basis}
    netax = ax in NET_OF
    L = lambda **k: [dict(base, **k).get(h, "") for h in PAIR_HEAD]
    eff = ax.startswith("eff_")
    if not src or not tgt:
        return [L(row="total", status="endpoint not declared")]

    def side(rung, tag):
        if tag:
            s, rs = G.endpoint_stats(tag, rung, cohort, ax)
            if s["n"]:
                return s, rs, f"{tag} endpoint runs (n {s['n']})"
        s = G.stats(rung, cohort, ax)
        return s, G.runs(rung, cohort), ("a modelled value (flagged: not a measurement)" if s["basis"] == "modelled"
                                         else "ladder runs")
    a, ar, aw = side(tgt, tgt_tag)
    b, br, bw = side(src, src_tag)
    tot = delta(a, b)
    ratio = (b["median"] / a["median"]) if a["n"] and b["n"] and a["median"] else None
    total = dict(row="total", n_rung=a["n"], n_pred=b["n"], delta=fmt(tot["delta"]), status=tot["status"],
                 granularity_q=fmt(tot["q"]), threshold=fmt(tot["threshold"]), source_median=fmt(b["median"]),
                 target_median=fmt(a["median"]), ratio_source_over_target=fmt(ratio),
                 util_coverage=coverage(ar + br) if eff else "", net_basis=net_basis(ar + br) if netax else "")
    ch = chain(levers, tgt)
    if src not in ch:
        return [L(note=f"totals: target from {aw}, source from {bw}; no per-lever path: {src} is not on {tgt}'s "
                       f"predecessor chain ({' <- '.join(ch)}) in ladder.levers.tsv; the total alone is not an attribution",
                  **total)]
    seq = [r for r in reversed(ch[:ch.index(src)]) if not not_run(levers[r], cohort)]
    steps = [r for r in seq if not alias_step(G, r, cohort)[0]]
    rows, ssum, missing, i = [], 0.0, [], 0
    for rung in seq:
        lv = levers[rung]
        pr, _ = run_pred(levers, rung, cohort)
        skip, anote = alias_step(G, rung, cohort)
        if skip:
            if SINGLE_LABEL in anote:
                # Ruling 2: a single-candidate selection has its own row, labelled, with no delta (not a
                # measured zero), no step number, and no part in the sum of the lever deltas.
                rows.append(L(row="lever", step="", rung=rung, predecessor=pr, lever=lv["lever"], delta="",
                              status=SINGLE_LABEL, note=anote))
            continue
        i += 1
        x, y = G.stats(rung, cohort, ax), G.stats(pr, cohort, ax, rung)
        d = delta(x, y)
        if d["delta"] is None:
            missing.append(rung)
        else:
            ssum += d["delta"]
        pb = pred_basis(levers, rung, cohort)
        rows.append(L(row="lever", step=i, rung=rung, predecessor=pr, lever=lv["lever"], n_rung=x["n"],
                      n_pred=y["n"], delta=fmt(d["delta"]), status=d["status"], granularity_q=fmt(d["q"]),
                      threshold=fmt(d["threshold"]),
                      note="; ".join(x for x in ("" if pb == "direct" else f"against the {pb}", anote,
                                                 rightsize_note(G, rung, cohort)) if x),
                      util_coverage=coverage(G.runs(rung, cohort) + G.runs(pr, cohort)) if eff else "",
                      net_basis=net_basis(G.runs(rung, cohort) + G.runs(pr, cohort)) if netax else ""))
    complete = not missing and tot["delta"] is not None
    ident = "endpoint runs" not in aw and "endpoint runs" not in bw
    note = f"totals: target from {aw}, source from {bw}"
    if missing:
        note += f"; steps missing medians: {', '.join(missing)}"
    elif not steps:
        note += "; source = target: no levers"
    elif complete:
        note += ("; residual is an identity (both totals are the values the lever rows use, so the deltas telescope)"
                 if ident else "; residual = endpoint-run total minus the ladder's lever deltas")
    rows.append(L(sum_of_lever_deltas=fmt(ssum) if complete else "incomplete",
                  residual_total_minus_sum=fmt(tot["delta"] - ssum) if complete else "", note=note, **total))
    return rows


def law1(runs, levers, defects, notes):
    """Per accession: file set and sha256 of every successful, contract-clean sample against a
    stock reference; every Law 1 DEFECT excludes its run. S5: an O-arm `differs` entry must match an
    S entry's rg_sha256; S entries that disagree with each other on rg_sha256 are flagged."""
    stock = set(stock_rungs(levers))
    by = {}
    for r in runs:
        for s in r["samples"]:
            if id(s) in r.get("bad_samples", set()) or s.get("rc") != 0:
                continue
            by.setdefault(str(s["accession"]), []).append((r, s))
    summ, det, s5rows, flags = [], [], [], []
    for acc in sorted(by):
        ent = sorted(by[acc], key=lambda e: (e[0]["params"]["arm"] != "S", e[0]["params"]["rung"] not in stock,
                                             e[0]["params"]["rung"], e[0]["run_id"], str(e[1].get("_node"))))
        s_ent = [e for e in ent if e[0]["params"]["arm"] == "S"]
        on_o = any(e[0]["params"]["arm"] == "O" for e in ent)
        ref = s_ent[0] if s_ent else None
        ref_stock = bool(ref and ref[0]["params"]["rung"] in stock)
        rmap = {k: v["sha256"] for k, v in ref[1]["outputs"].items()} if ref else {}
        bad = []
        if on_o and not ref_stock:
            e = "no stock reference for an accession on the O arm" + ("" if ref else " (no S-arm entry)")
            bad.append(e)
            for r, _ in ent:
                if r["params"]["arm"] == "O":
                    r["exclude"].append(f"DEFECT (Law 1): {acc}: {e}")
        s_rg = {}
        for r, s in s_ent:
            if s5_of(s)[0] == "differs":
                s_rg.setdefault(tuple(s["s5"]["rg_sha256"]), []).append(r["run_id"])
        if len(s_rg) > 1:
            flags.append(f"{acc}: S-arm s5 differs entries disagree on rg_sha256 ({len(s_rg)} distinct: "
                         + "; ".join(", ".join(v) for v in s_rg.values()) + ")")
        for r, s in ent:
            omap = {k: v["sha256"] for k, v in s["outputs"].items()}
            arm, rung = r["params"]["arm"], r["params"]["rung"]
            if ref is None:
                st = "no upstream reference"
            elif r is ref[0] and s is ref[1]:
                st = "reference"
            elif set(omap) != set(rmap):
                st = (f"DEFECT: file set differs from the reference (missing {','.join(sorted(set(rmap) - set(omap))) or '-'}; "
                      f"extra {','.join(sorted(set(omap) - set(rmap))) or '-'})")
            elif omap != rmap:
                st = "DEFECT: sha256 differs from the reference on " + ",".join(k for k in sorted(omap) if omap[k] != rmap.get(k))
            else:
                st = "identical"
            if st.startswith("DEFECT"):
                bad.append(f"{r['run_id']}: {st}")
                r["exclude"].append(f"DEFECT (Law 1): {acc}: {st[8:]}")
            if s5_of(s)[0] == "differs":
                rg = tuple(s["s5"]["rg_sha256"])
                if arm == "O":
                    match = s_rg.get(rg)
                    if match:
                        chk = f"rg_sha256 matches the S entry {match[0]}"
                    else:
                        chk = "DEFECT: O-arm s5 differs and no S entry has the same rg_sha256"
                        bad.append(f"{r['run_id']}: {chk}")
                        r["exclude"].append(f"DEFECT (Law 1): {acc}: {chk[8:]}")
                else:
                    chk = "S rapidgzip output" + (": disagrees with another S entry (flagged)" if len(s_rg) > 1 else "")
                s5rows.append([acc, r["run_id"], arm, rung, r["params"]["cohort"], "differs", s5_of(s)[1],
                               s["s5"].get("P", ""), s["s5"].get("nproc", ""), ",".join(rg),
                               "yes" if ref and omap == rmap else "no", st, chk])
            for role in sorted(set(omap) | set(rmap)):
                o = s["outputs"].get(role) or {}
                det.append([acc, r["run_id"], s.get("_node", ""), arm, rung, r["params"]["cohort"], role, o.get("bytes", ""),
                            o.get("sha256", "absent"), rmap.get(role, "absent"), st])
        for b in bad:
            defects.append(("Law 1", f"{acc} {b}"))
        if bad:
            status = "DEFECT"
        elif not ref:
            status = "no upstream reference"
        elif len(ent) > 1:
            status = "identical"
        else:
            status = "one entry: nothing to compare"
        summ.append([acc, len(ent), ",".join(sorted({e[0]["params"]["arm"] for e in ent})),
                     ",".join(sorted({e[0]["params"]["rung"] for e in ent})),
                     f"{ref[0]['run_id']} ({ref[0]['params']['rung']}{'' if ref_stock else ', not a stock rung'})" if ref
                     else "none", ",".join(sorted(rmap)), status, "; ".join(bad)])
    for r in runs:
        r["exclude"] = list(dict.fromkeys(r["exclude"]))
    return summ, det, s5rows, flags


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
                    if s5_of(s) == ("differs", "gzip") and not gzip_failed(s):
                        x[0].add(str(s["accession"]))
    for rung, (fb, allacc) in sorted(by.items()):
        if fb:
            out.append(f"{rung}: S5 not output-preserving on {len(fb)} of {len(allacc)} inputs (fell back to gzip): "
                       f"{', '.join(sorted(fb))}")
    return out


class _RecordedSink:
    """The defects list as validate() sees it for a recorded run: contract and incomplete DEFECTs are
    dropped (the run is a recorded defect), every other class goes through."""

    def __init__(self, defects, run):
        self.defects, self.run = defects, run

    def append(self, d):
        if d[0] not in RECORDED_CLASSES:
            self.defects.append(d)


def build(runs, levers, campaign_spend=None, modelled=None, resolved=None, pair_checks=None, recorded=None):
    modelled = modelled or {}
    T, defects, notes = {}, [], []
    emap, eerr = declared_endpoints(levers)
    for e in eerr:
        defects.append(("levers", e))
    validate(runs, levers, defects, recorded)
    # GNU gzip's warning (exit 2: trailing data ignored, the output complete): kept, never an input
    # defect, but named, sample by sample (tidy.tsv s5.gz_warning and here).
    for r in runs:
        for s in r["samples"]:
            w = gz_warned(s)
            if w:
                notes.append(f"gz_warning: {r['run_id']} {s.get('accession')}: GNU gzip exited 2 (its warning: trailing data "
                             f"ignored, the output complete) on {', '.join(w)}; the input is kept, not an input defect")
    l1, det, s5rows, s5flags = law1(runs, levers, defects, notes)
    G = Groups(runs, levers, modelled, emap, notes, resolved, pair_checks)

    # 1. runs.tsv and tidy.tsv
    rh = ["run_id", "gate", "kind", "arm", "rung", "cohort", "rep", "run_kind", "endpoint", "state", "type", "nodes", "az",
          "commit", "price_usd_per_h", "wall_s", "wall_net_s", "critical_measurement_s", "net_components", "net_basis", "billed_usd", "billed_net_usd", "lever_phase", "lever_phase_s", "planned_samples", "samples",
          "pairs"] + U_COLS + ["util_cost_usd"] + [e for e, _ in EFF] + [en for en, _ in EFF_NET] + \
        ["util_coverage", "in_attribution", "notes"]
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
               fmt(r["wall_s"], 1), fmt(r["wall_net_s"], 3),
               ";".join(f"r{k}={v:.3f}" for k, v in sorted(r["net"]["critical"].items(), key=lambda kv: str(kv[0]))),
               ";".join(f"r{n['rank']}=" + ",".join(f"{k[:-2]}:{L[0][k]:.3f}" for k in NET_PARTS if k in L[0])
                        for n in r.get("nodes_info", []) for L in [[x for x in n["lad_net"] if isinstance(x, dict)]]
                        if len(L) == 1 and any(k in L[0] for k in NET_PARTS)),
               r["net"]["basis"],
               fmt(r["billed_usd"]), fmt(r["billed_net_usd"]), lp, fmt(phase_value(r, lp)[0], 3),
               "" if r["planned"] is None else len(r["planned"]), len(r["samples"]), pairs] + \
              [fmt(u.get(k)) for k in U_COLS] + [fmt(u.get("cost_usd"))] + [fmt(r["eff"][e]) for e, _ in EFF] + \
              [fmt(axis_value(r, en, levers, p["rung"])[0]) for en, _ in EFF_NET] + \
              [r["util_coverage"], inattr, "; ".join(r["notes"])]
        rows.append(row)
        base = [r["run_id"], p.get("arm", ""), p["rung"], p.get("cohort", ""), p["rep"], p["run_kind"], p["state"]]
        for k, v in (("wall_s", fmt(r["wall_s"], 1)), ("wall_net_s", fmt(r["wall_net_s"], 3)),
                     ("billed_usd", fmt(r["billed_usd"])), ("billed_net_usd", fmt(r["billed_net_usd"]))):
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
            tidy.append(sb + ["s5.gz_warning", ";".join(gz_warned(s)) or "none"])
    T["runs.tsv"] = (rh, rows)
    T["tidy.tsv"] = (["run_id", "arm", "rung", "cohort", "rep", "run_kind", "state", "node", "accession", "idx", "metric",
                      "value"], tidy)

    keys = set(G.g) | {(r, c) for r, c, _ in modelled}
    cs = {c for _, c in keys}
    keys = sorted(keys | {(r, c) for r, lv in levers.items() if lv.get("alias") for c in cs}
                  | {(r, c) for r, lv in levers.items() for c in (lv.get("alias_cohorts") or {}) if c in cs})
    for (rung, c), rs in sorted(G.g.items()):
        t = pair_alias(levers, G.pair_checks, rung, c)
        if t:
            notes.append(f"{len(rs)} run(s) of {rung} at c{c}, where it is an alias of {t} (alias_cohorts): not used; "
                         f"{rung} reads {t}'s runs there")
    for (rung, c) in keys:
        if (levers.get(rung) or {}).get("alias") and G.alias(rung, c)[0] is None:
            have = [x for x in levers[rung]["alias_of"] if G.runs(x, c)]
            if have:
                notes.append(f"{rung} is unresolved at c{c} although its candidates {', '.join(have)} have runs there "
                             f"({G.alias(rung, c)[1]})")
    # 2. rungs.tsv (and 4. effcost.tsv)
    srows, erows = [], []
    for (rung, cohort) in keys:
        arm = (levers.get(rung) or {}).get("arm", rung[:1])
        for ax in AXES:
            s = G.stats(rung, cohort, ax)
            srows.append([arm, rung, cohort, ax, SERIES.get(ax, ""),
                          (levers.get(rung) or {}).get("phase", "") if ax == "lever_phase_s" else "",
                          s.get("basis_note", "measured"), s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2", fmt(s["q"])])
        rs = G.runs(rung, cohort)
        missing = sum(1 for r in rs if r["util"] is None)
        for ax in U_COLS + [x for (en, e) in EFF_NET for x in (en, e)]:
            s = G.stats(rung, cohort, ax)
            erows.append([arm, rung, cohort, ax, SERIES.get(ax, ""), s["n"], fmt(s["median"]), fmt(s["min"]), fmt(s["max"]),
                          fmt(s["range"]) if s["n"] >= 2 else "n<2", fmt(s["q"]), coverage(rs),
                          f"util missing on {missing} of {len(rs)} run(s): not imputed" if missing else ""])
    T["rungs.tsv"] = (["arm", "rung", "cohort", "axis", "series", "lever_phase", "basis", "n", "median", "min", "max",
                       "range", "granularity_q"], srows)
    T["effcost.tsv"] = (["arm", "rung", "cohort", "metric", "series", "n", "median", "min", "max", "range", "granularity_q",
                         "util_coverage", "note"], erows)

    # 3. deltas.tsv
    dh = ["arm", "rung", "predecessor", "predecessor_basis", "lever", "counterpart", "cohort", "axis", "series", "lever_phase",
          "n_rung", "n_pred", "median_rung", "median_pred", "delta", "range_rung", "range_pred", "measured_spread",
          "granularity_q", "threshold", "status", "predicted_delta", "predicted_resolvable", "net_basis"]
    drows = []
    for cohort in sorted({c for _, c in keys}):
        for rung, lv in sorted(levers.items()):
            if not_run(lv, cohort):
                for ax in AXES:
                    drows.append([lv["arm"], rung, lv["predecessor"], "", lv["lever"], lv["counterpart"], cohort, ax,
                                  SERIES.get(ax, ""), "", "", "", "", "", "", "", "", "", "", "", not_run(lv, cohort), "", "", ""])
    for (rung, cohort) in keys:
        lv = levers.get(rung)
        if not lv or not lv["predecessor"] or not_run(lv, cohort):
            continue
        pr, _ = run_pred(levers, rung, cohort)
        pb = pred_basis(levers, rung, cohort)
        skip, anote = alias_step(G, rung, cohort)
        if anote:
            pbcol = anote if pb == "direct" else f"{pb}; {anote}"
        else:
            pbcol = pb
        if rightsize_note(G, rung, cohort):
            pbcol = f"{pbcol}; {RIGHTSIZE_NOTE}"
        for ax in AXES:
            a, b = G.stats(rung, cohort, ax), G.stats(pr, cohort, ax, rung)
            d = delta(a, b, num(lv.get(PRED_COL[ax])))
            if skip:
                d = dict(d, delta=None, status=anote, measured_spread=None, q=None, threshold=None, predicted_resolvable="")
            rows_net = net_basis(G.runs(rung, cohort) + G.runs(pr, cohort)) if ax in NET_OF else ""
            plain = skip or d["status"] == "alias unresolved" or pb == "direct"
            drows.append([lv["arm"], rung, pr, pbcol, lv["lever"], lv["counterpart"], cohort, ax, SERIES.get(ax, ""),
                          lv["phase"] if ax == "lever_phase_s" else "", a["n"], b["n"], fmt(a["median"]), fmt(b["median"]),
                          fmt(d["delta"]), fmt(a["range"]), fmt(b["range"]), fmt(d["measured_spread"]), fmt(d["q"]),
                          fmt(d["threshold"]), d["status"] + ("" if plain else f" (against the {pb})"),
                          fmt(d["predicted"]), d["predicted_resolvable"] or ("no prediction" if d["predicted"] is None else ""),
                          rows_net])
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
                                  "nproc", "rg_sha256", "outputs_equal_reference", "law1_status", "s5_check"], s5rows)

    # 7. endpoint decomposition runs: cold and warm rows
    eg = {}
    for r in runs:
        p = r["params"]
        if p["run_kind"] == "endpoint" and not r["exclude"]:
            eg.setdefault((p.get("arm", ""), p["endpoint"], p["rung"], p.get("cohort", ""), p["state"]), []).append(r)
    erows = []
    for k in sorted(eg, key=lambda k: tuple(str(x) for x in k)):
        rs = eg[k]
        metrics = ["wall_net_s", "wall_s", "billed_net_usd", "billed_usd"] + \
            [f"phase.{n}" for n in sorted({n for r in rs for n in r["phases_run"]})]
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
    findings = s5_findings(runs, levers) + s5flags
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
        if r[ix["axis"]] not in ("wall_net_s", "wall_s", "billed_net_usd", "billed_usd"):
            continue
        cur.append(r)
        if r[ix["row"]] == "total":
            blocks.append(cur)
            cur = []
    if blocks:
        L += ["## Pairs (net is the headline, gross beside it: wall on the time endpoint, billed $ on the cost endpoint; "
              "every axis is in pairs.tsv)", "",
              "Net wall = the max over nodes of (terminated_at - that node's lad-net critical_measurement_s, the "
              "measurement-only seconds as the ladder body defines them) - the first launch (Scott, 2026-10-10); net billed "
              "is prorated (billed x net/gross). Each total is followed by its per-lever rows (Law 5).", "",
              "| pair | cohort | axis | series | source | target | endpoint basis | row | rung | delta | status | "
              "ratio source/target | sum of lever deltas | net basis | note |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for b in blocks:
            t = b[-1]
            g = lambda r, k: r[ix[k]]
            L.append(f"| {g(t, 'pair')} | {g(t, 'cohort')} | {g(t, 'axis')} | {g(t, 'series')} | {g(t, 'source')} | "
                     f"{g(t, 'target')} | {g(t, 'endpoint_basis')} | **total** | | {g(t, 'delta')} | {g(t, 'status')} | "
                     f"{g(t, 'ratio_source_over_target')} | {g(t, 'sum_of_lever_deltas')} | {g(t, 'net_basis')} | "
                     f"{g(t, 'note')} |")
            for r in b[:-1]:
                L.append(f"| | | | | | | | lever {g(r, 'step')} | {g(r, 'rung')} ({g(r, 'lever')}) | {g(r, 'delta')} | "
                         f"{g(r, 'status')} | | | | {g(r, 'note')} |")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", default=os.path.join(ROOT, "results"))
    ap.add_argument("--levers", default=os.path.join(ROOT, "scripts", "g3", "ladder.levers.tsv"))
    ap.add_argument("--modelled", default=None, help="modelled values (default <results>/g3/ladder-modelled.tsv)")
    ap.add_argument("--resolved", default=os.path.join(ROOT, "scripts", "g3", "ladder.resolved.tsv"),
                    help="alias winners and placeholder resolutions (ladder.resolved.tsv)")
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "g3", "ladder"))
    ap.add_argument("--recorded", default=os.path.join(ROOT, "scripts", "lib", "g3_defects.tsv"),
                    help="runs already recorded as defects (scripts/lib/g3_defects.tsv): excluded once, contract and "
                         "incomplete checks not re-raised")
    ap.add_argument("--spend", default=None, help="campaign spend.tsv (default <results>/g3/campaign/spend.tsv)")
    a = ap.parse_args(argv)
    rd = Reader()
    levers = load_levers(a.levers, rd)
    mpath = a.modelled or os.path.join(a.results, "g3", "ladder-modelled.tsv")
    modelled, refused = load_modelled(mpath, rd, os.path.dirname(os.path.abspath(a.results)), a.results, a.levers)
    runs = discover(a.results, rd)
    spend_p = a.spend or os.path.join(a.results, "g3", "campaign", "spend.tsv")
    cs = None
    if os.path.exists(spend_p):
        cs = {r.get("run") for r in csv.DictReader(rd.text(spend_p).splitlines(), delimiter="\t")}
    resolved, rerrs = load_resolved(a.resolved, rd, levers, os.path.dirname(os.path.abspath(a.results)))
    nrnotes = not_run_cond_checks(a.levers, a.resolved, levers, {r['params'].get('cohort') for r in runs})
    pchk, pdef = alias_cohort_checks(a.levers, a.resolved, levers)
    T, defects, notes, excl, findings = build(runs, levers, cs, modelled, resolved, pchk, load_recorded(a.recorded, rd))
    notes += nrnotes
    defects += pdef
    notes += [f"{r} at c{c}: alias_cohorts pair not used: {why}" for (r, c), why in sorted(pchk.items())
              if why and not why.startswith(NOT_ALIAS)]
    notes += [f"{r} at c{c}: conditional alias_cohorts entry: {why[len(NOT_ALIAS):]}, so it reads its own runs"
              for (r, c), why in sorted(pchk.items()) if why.startswith(NOT_ALIAS)]
    notes += [f"{r} at c{c}: {note}" for (r, c), (w, note) in sorted(resolved.items()) if w is None and "cites do not verify" in note]
    defects += [("modelled", f"refused: {x}") for x in refused] + [("resolved", x) for x in rerrs]
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
           "resolved": rel(os.path.abspath(a.resolved)) if os.path.exists(a.resolved) else None,
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
