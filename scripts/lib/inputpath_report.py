#!/usr/bin/env python3
"""make inputpath-report RUN=results/inputpath/<run-id> [OUT=...] (#90; docs/inputpath.md,
"Records and report"). Python 3 stdlib only.

Reads only the run dir:
  manifest.json      run.sh's manifest (instance, AMI, AZ, truffle price, billed seconds,
                     cost_usd, commit, upstream pin); must be finalised.
  out/points.jsonl   one JSON object per kraken2 run point (schema below).
  <pidstat_csv>      per point, a path relative to the run dir (schema below).
Writes markdown to stdout and to OUT (default <run>/tables/inputpath-report.md), and the
per-setting summary to <run>/tables/inputpath-summary.tsv.

Exit: 0 report written, no defect; 1 report written and at least one DEFECT line (Law 1
mismatch, a used point that failed its identity check, an ok point missing a required field,
or a status=defect point); 2 usage or unreadable input (missing run dir or manifest, manifest
not finalised, invalid JSON, no points).

Record schema, out/points.jsonl (schema "inputpath-point/1"; R = required on status ok,
O = optional, shown as "missing" when absent; n/a = not applicable to the arm):
{
  "schema":        "inputpath-point/1",                         O
  "point_id":      str, unique in the file                       R
  "rep":           int, repetition of the same setting (1..)     O (default 1)
  "arm":           "I0"|"I1"|"I2"|"I3"|"I4"                      R
  "engine":        "upstream"|"ours"                             R
  "family":        "c8g"|"c9g"|"c8gn"|...                        R
  "instance_type": str (must equal manifest .instance.type)      R
  "db":            str, database name                            O
  "p":             int, rapidgzip -P per mate (I2..I4)           R for I2..I4, n/a for I0/I1
  "threads":       int, kraken2 --threads                        R
  "chunk_mib":     int, rapidgzip --chunk-size in MiB            O (I2..I4)
  "thp":           "always"|"never"                              R
  "pipe_bytes":    int, F_SETPIPE_SZ on the decoder's stdout     O
  "fanout":        int, ours' fan-out width                      O (ours only)
  "rapidgzip":     {"version": str, "build": "pypi"|"source", "isal": bool}   O (I2..I4)
  "input":         {"role": "paired"|"single", "accession": str,             R (accession)
                    "mates": [{"mate": 1|2, "s3_key": str, "sha256": str}]}   O (mates)
  "index_sha256":  str (I3)                                      O
  "bgzf_sha256":   str (I4)                                      O
  "fastq_bytes":   int, decompressed FASTQ bytes over all mates  O (used if fastq_mb_per_s absent)
  "wall_s":        number, kraken2 wall time for the point       R
  "classify_reads_per_s": number                                 O
  "fastq_mb_per_s": number (MB = 10^6 bytes)                     O
  "classify_window": {"t0": s, "t1": s} in the pidstat CSV's t_s time base   O
  "pidstat_csv":   str, path relative to the run dir             O
  "peak_rss_kb":   {"kraken2": int, "rapidgzip": int, ...}       O
  "output_sha256": str, sha256 of --output                       R
  "report_sha256": str, sha256 of --report                       R
  "identity":      {"gz_sha256": str, "rg_sha256": str, "rg_exit": int, "ok": bool}
                                                                 R for I2..I4 with status ok
  "status":        "ok"|"skipped"|"defect"                       R
  "note":          str                                           O
}
status skipped = recorded, never used (e.g. a rapidgzip crash or identity mismatch); it is listed
and excluded from every table and reading. status defect = the harness's own defect; listed as a
DEFECT.

pidstat CSV schema (one row per thread per 1 s sample, from `pidstat -t 1`):
  header: t_s,tgid,tid,command,role,cpu_pct
  role: rapidgzip | gzip | kraken2_reader | kraken2_worker | kraken2_other | other
  (role may be empty for kraken2 threads; then the reader is inferred as the kraken2 thread with
   the highest mean %CPU in the window and labelled "inferred").
"""
import csv
import hashlib
import json
import os
import statistics
import subprocess
import sys

SCHEMA = "inputpath-point/1"
ARMS = ["I0", "I1", "I2", "I3", "I4"]
RG_ARMS = {"I2", "I3", "I4"}
REQUIRED = ["point_id", "arm", "engine", "family", "instance_type", "threads", "thp",
            "wall_s", "output_sha256", "report_sha256", "status"]

# The reading rules' thresholds (docs/inputpath.md, "Reading rules"). Change them there too.
WITHIN = 0.05          # R1: "I1 within 5% of I0"; also the resolution every comparison needs
REACH_SINGLE = 0.05    # R2: "reaches" when either side has a single point
REACH_FLOOR = 0.01     # R2: lower bound on the noise tolerance of repeated points
READER_SAT = 90.0      # R3: reader thread mean %CPU over the classify window, >= this
WORKER_IDLE = 50.0     # R3: kraken2 worker mean %CPU over the window, < this
PIPE_GAP = 0.10        # the plan's pipe-cost line: I2 at best p vs I0 under 10%
ROLES = ["rapidgzip", "gzip", "kraken2_reader", "kraken2_worker", "kraken2_other", "other"]

MISSING = "missing"


def die(msg):
    print(f"make inputpath-report: {msg}", file=sys.stderr)
    sys.exit(2)


def _git_head():
    try:
        return subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(__file__)),
                               "rev-parse", "HEAD"], capture_output=True, text=True,
                              timeout=10).stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fmt(v, nd=1):
    if v is None:
        return MISSING
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def pct(x):
    return f"{100 * x:+.1f}%"


# ---------------------------------------------------------------------------------------------
# Loading

def load_manifest(run):
    path = os.path.join(run, "manifest.json")
    if not os.path.isfile(path):
        die(f"{path}: no manifest")
    try:
        with open(path) as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        die(f"{path}: invalid JSON ({e})")
    if not m.get("manifest_finalised_at"):
        die(f"{path}: not finalised (manifest_finalised_at unset); the run is in progress or "
            "aborted")
    return m


def load_points(run):
    path = os.path.join(run, "out", "points.jsonl")
    if not os.path.isfile(path):
        die(f"{path}: no point records")
    pts = []
    with open(path) as f:
        for ln, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except ValueError as e:
                die(f"{path}:{ln}: invalid JSON ({e})")
            if not isinstance(o, dict):
                die(f"{path}:{ln}: not a JSON object")
            o["_src"] = f"L{ln}"
            pts.append(o)
    if not pts:
        die(f"{path}: empty")
    return pts


def accession(p):
    inp = p.get("input") or {}
    return inp.get("accession") or MISSING


def role_of(p):
    return (p.get("input") or {}).get("role") or MISSING


def validate(points, manifest, defects):
    """Moves points with problems out of use; appends DEFECT lines. Returns usable points."""
    usable, seen = [], set()
    mtype = (manifest.get("instance") or {}).get("type")
    for p in points:
        src = "out/points.jsonl:" + p["_src"]
        pid = p.get("point_id", p["_src"])
        if pid in seen:
            defects.append(f"DEFECT (record) {pid} ({src}): duplicate point_id")
        seen.add(pid)
        st = p.get("status")
        if st == "skipped":
            continue
        if st == "defect":
            defects.append(f"DEFECT (harness) {pid} ({src}): status defect: "
                           f"{p.get('note', MISSING)}")
            continue
        if st != "ok":
            defects.append(f"DEFECT (record) {pid} ({src}): status {st!r} is not ok|skipped|defect")
            continue
        miss = [k for k in REQUIRED if p.get(k) in (None, "")]
        if accession(p) == MISSING:
            miss.append("input.accession")
        if p.get("arm") in RG_ARMS:
            if p.get("p") is None:
                miss.append("p")
            if not isinstance(p.get("identity"), dict):
                miss.append("identity")
        if miss:
            defects.append(f"DEFECT (record) {pid} ({src}): status ok but missing required "
                           f"{', '.join(miss)}")
            continue
        if p["arm"] not in ARMS:
            defects.append(f"DEFECT (record) {pid} ({src}): arm {p['arm']!r} not in I0..I4")
            continue
        if p["thp"] not in ("always", "never"):
            defects.append(f"DEFECT (record) {pid} ({src}): thp {p['thp']!r} not always|never")
            continue
        if p["arm"] in RG_ARMS:
            idn = p["identity"]
            if not (idn.get("ok") is True and idn.get("rg_exit") == 0
                    and idn.get("gz_sha256") and idn.get("gz_sha256") == idn.get("rg_sha256")):
                defects.append(
                    f"DEFECT (identity) {pid} ({src}): used (status ok) although its rapidgzip "
                    f"identity check failed: rg_exit {idn.get('rg_exit', MISSING)}, gz "
                    f"{str(idn.get('gz_sha256', MISSING))[:12]}, rg "
                    f"{str(idn.get('rg_sha256', MISSING))[:12]}, ok {idn.get('ok', MISSING)}")
                continue
        if mtype and p["instance_type"] != mtype:
            defects.append(f"DEFECT (record) {pid} ({src}): instance_type {p['instance_type']} "
                           f"!= manifest .instance.type {mtype}")
            continue
        usable.append(p)
    return usable


def law1(points, defects, lines):
    """Every usable point's output and report sha256 must equal I0's for the same input and db.
    The reference is upstream's I0 (Law 1: upstream at the pin is the oracle), else ours' I0."""
    groups, bad_ids = {}, set()
    for p in points:
        groups.setdefault((accession(p), p.get("db", "")), []).append(p)
    for (acc, db), ps in sorted(groups.items()):
        refs = [p for p in ps if p["arm"] == "I0" and p["engine"] == "upstream"] or \
               [p for p in ps if p["arm"] == "I0"]
        if not refs:
            lines.append(f"- {acc}: Law 1 unchecked, no usable I0 point; "
                         f"{len(ps)} points unverified")
            for p in ps:
                bad_ids.add(p["point_id"])
                defects.append(f"DEFECT (Law 1 unverifiable) {p['point_id']} "
                               f"(out/points.jsonl:{p['_src']}): no I0 reference for {acc}")
            continue
        ref = refs[0]
        rh = (ref["output_sha256"], ref["report_sha256"])
        bad = 0
        for p in ps:
            h = (p["output_sha256"], p["report_sha256"])
            if h != rh:
                bad += 1
                bad_ids.add(p["point_id"])
                what = [n for n, a, b in (("output", h[0], rh[0]), ("report", h[1], rh[1]))
                        if a != b]
                defects.append(
                    f"DEFECT (Law 1) {p['point_id']} (out/points.jsonl:{p['_src']}): "
                    f"{' and '.join(what)} sha256 differ from I0 {ref['point_id']} "
                    f"(out/points.jsonl:{ref['_src']}): output {p['output_sha256'][:12]} vs "
                    f"{rh[0][:12]}, report {p['report_sha256'][:12]} vs {rh[1][:12]}")
        lines.append(f"- {acc}: {len(ps) - bad} of {len(ps)} points match I0 "
                     f"{ref['point_id']} (out/points.jsonl:{ref['_src']}; output "
                     f"`{rh[0][:12]}`, report `{rh[1][:12]}`)")
    return bad_ids


# ---------------------------------------------------------------------------------------------
# Settings (repeated points of one setting are aggregated)

def setting_key(p):
    return (p["arm"], p.get("p"), p["threads"], p.get("chunk_mib"), p["thp"],
            p.get("pipe_bytes"), p.get("fanout"))


class Setting:
    def __init__(self, pts):
        self.pts = sorted(pts, key=lambda q: (q.get("rep", 1), q["_src"]))
        p0 = self.pts[0]
        self.arm, self.p, self.threads = p0["arm"], p0.get("p"), p0["threads"]
        self.chunk, self.thp, self.pipe = p0.get("chunk_mib"), p0["thp"], p0.get("pipe_bytes")
        self.fanout = p0.get("fanout")
        walls = [float(q["wall_s"]) for q in self.pts]
        self.n = len(walls)
        self.wall = statistics.median(walls)
        self.wmin, self.wmax = min(walls), max(walls)
        self.src = ",".join(q["_src"] for q in self.pts)
        # The representative point (CPU attribution): the one whose wall is nearest the median.
        self.rep = min(self.pts, key=lambda q: (abs(float(q["wall_s"]) - self.wall), q["_src"]))

    def mbps(self):
        vals = []
        for q in self.pts:
            if q.get("fastq_mb_per_s") is not None:
                vals.append(float(q["fastq_mb_per_s"]))
            elif q.get("fastq_bytes") is not None:
                vals.append(float(q["fastq_bytes"]) / 1e6 / float(q["wall_s"]))
        return statistics.median(vals) if vals else None

    def rps(self):
        vals = [float(q["classify_reads_per_s"]) for q in self.pts
                if q.get("classify_reads_per_s") is not None]
        return statistics.median(vals) if vals else None

    def rss(self, proc):
        vals = [(q.get("peak_rss_kb") or {}).get(proc) for q in self.pts]
        vals = [v for v in vals if v is not None]
        return max(vals) if vals else None

    def label(self):
        s = f"{self.arm} t{self.threads} thp={self.thp}"
        if self.p is not None:
            s += f" p{self.p}"
        if self.chunk is not None:
            s += f" chunk {self.chunk} MiB"
        return s


def na_or(v, arm, applies_to=RG_ARMS):
    if arm not in applies_to:
        return "n/a"
    return MISSING if v is None else str(v)


# ---------------------------------------------------------------------------------------------
# Comparisons

def compare(x, ref, tol_single, rule):
    """Relative wall difference of setting x against ref, and whether it is within tolerance.
    rule 'within': tolerance WITHIN always. rule 'reach': tolerance = the larger min-max spread of
    the two settings (relative to ref, at least REACH_FLOOR) when both are repeated, else
    tol_single. Either rule: when both are repeated and that spread exceeds WITHIN, the probe
    cannot resolve a 5% effect and the comparison is 'unresolved'."""
    d = (x.wall - ref.wall) / ref.wall
    noise = None
    if x.n >= 2 and ref.n >= 2:
        noise = max(x.wmax - x.wmin, ref.wmax - ref.wmin) / ref.wall
    if noise is not None and noise > WITHIN:
        return d, None, noise, "unresolved"
    if rule == "within":
        tol = WITHIN
    else:
        tol = max(noise, REACH_FLOOR) if noise is not None else tol_single
    return d, tol, noise, ("yes" if d <= tol else "no")


def cmp_text(x, ref, d, tol, noise):
    t = (f"{x.label()} {x.wall:.1f} s (n={x.n}, {x.src}) vs {ref.label()} {ref.wall:.1f} s "
         f"(n={ref.n}, {ref.src}): {pct(d)}")
    if noise is not None:
        t += f", noise {100 * noise:.1f}%"
    if tol is not None:
        t += f", tolerance {100 * tol:.1f}%"
    return t


def best(settings, arm, **match):
    c = [s for s in settings if s.arm == arm and all(getattr(s, k) == v for k, v in match.items())]
    return min(c, key=lambda s: (s.wall, s.src)) if c else None


def reading_r1(settings):
    i0 = [s for s in settings if s.arm == "I0"]
    i1 = [s for s in settings if s.arm == "I1"]
    if not i0 or not i1:
        return "undecided", "no usable " + ("I0" if not i0 else "I1") + " point"
    pairs = []
    for a in i1:
        r = best(settings, "I0", threads=a.threads, thp=a.thp)
        if r:
            pairs.append((a, r))
    if not pairs:
        return "undecided", "no I1 setting has an I0 point at the same threads and thp"
    out, worst, unres = [], None, []
    for a, r in pairs:
        d, tol, noise, v = compare(a, r, WITHIN, "within")
        txt = cmp_text(a, r, d, tol, noise)
        if v == "unresolved":
            unres.append(txt)
        elif v == "no":
            out.append(txt)
        if worst is None or d > worst[0]:
            worst = (d, txt)
    if out:
        return "does not apply", "I1 exceeds I0 by more than 5% at " + "; ".join(out)
    if unres:
        return "undecided", ("the repeated points' spread exceeds 5%, so a 5% effect cannot be "
                             "resolved: " + "; ".join(unres))
    return "applies", (f"I1 within 5% of I0 at all {len(pairs)} matched setting(s); worst "
                       f"{worst[1]}. Strike single-stream gzip from H-knee")


def reading_r2(settings):
    ref = best(settings, "I0")
    if ref is None:
        return "undecided", "no usable I0 point", None
    cands = [s for s in settings if s.arm in ("I2", "I3") and s.threads == ref.threads
             and s.thp == ref.thp]
    if not cands:
        return ("undecided", f"no I2 or I3 point at I0's best setting ({ref.label()}, "
                f"{ref.src})", None)
    by_p = {}
    for s in cands:
        k = (s.p, s.arm)
        if k not in by_p or s.wall < by_p[k].wall:
            by_p[k] = s
    reached, unres, notyet = [], [], []
    for (p, arm), s in sorted(by_p.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        d, tol, noise, v = compare(s, ref, REACH_SINGLE, "reach")
        txt = cmp_text(s, ref, d, tol, noise)
        {"yes": reached, "no": notyet, "unresolved": unres}[v].append((p, arm, txt))
    i2 = [s for s in by_p.values() if s.arm == "I2"]
    gap_txt = None
    if i2:
        gap = min(i2, key=lambda s: (s.wall, s.src))
        g = (gap.wall - ref.wall) / ref.wall
        gap_txt = (f"Pipe cost (I2 at its best p vs I0): {pct(g)} ({gap.label()}, {gap.src}); "
                   + (f"under {100 * PIPE_GAP:.0f}%, so by the plan the pipe work and "
                      "in-process decode can wait behind prefetching" if g < PIPE_GAP else
                      f"not under {100 * PIPE_GAP:.0f}%"))
    if reached:
        p, arm, txt = reached[0]
        extra = ""
        if any(u[0] < p for u in unres):
            extra = (f"; smaller p unresolved: " +
                     "; ".join(u[2] for u in unres if u[0] < p))
            return ("undecided", f"{arm} reaches I0 at p={p} ({txt}), but a smaller p cannot be "
                    f"ruled out{extra}", gap_txt)
        return ("applies", f"{arm} reaches I0 at p={p}, the smallest such p, the recommended "
                f"setting: {txt}", gap_txt)
    if unres:
        return ("undecided", "no p reaches I0 within resolution: " +
                "; ".join(u[2] for u in unres), gap_txt)
    return ("does not apply", "no I2/I3 p reaches I0: " + "; ".join(n[2] for n in notyet),
            gap_txt)


def read_pidstat(run, p):
    """Mean %CPU per thread over the classify window, by role. Returns (dict, note) or
    (None, reason)."""
    rel = p.get("pidstat_csv")
    if not rel:
        return None, "pidstat_csv missing"
    path = os.path.normpath(os.path.join(run, rel))
    if not path.startswith(os.path.normpath(run) + os.sep) or not os.path.isfile(path):
        return None, f"{rel}: not a file in the run dir"
    win = p.get("classify_window") or {}
    t0, t1 = win.get("t0"), win.get("t1")
    per = {}
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        need = {"t_s", "tid", "command", "role", "cpu_pct"}
        if not need <= set(r.fieldnames or []):
            return None, f"{rel}: header lacks {', '.join(sorted(need - set(r.fieldnames or [])))}"
        for row in r:
            t = float(row["t_s"])
            if t0 is not None and t < float(t0):
                continue
            if t1 is not None and t > float(t1):
                continue
            k = (row["tid"], row["command"], row["role"])
            per.setdefault(k, []).append(float(row["cpu_pct"]))
    if not per:
        return None, f"{rel}: no samples in the classify window"
    threads = [(tid, cmd, role, statistics.mean(v)) for (tid, cmd, role), v in per.items()]
    inferred = False
    unroled = [t for t in threads if not t[2] and "kraken2" in t[1]]
    if unroled:
        inferred = True
        top = max(unroled, key=lambda t: t[3])
        threads = [(tid, cmd, role or ("kraken2_reader" if (tid, cmd) == (top[0], top[1])
                                       else ("kraken2_worker" if "kraken2" in cmd else "other")),
                    m) for tid, cmd, role, m in threads]
    threads = [(tid, cmd, role if role in ROLES else ("other" if role else
                ("rapidgzip" if "rapidgzip" in cmd else
                 "gzip" if cmd in ("gzip", "pigz") else "other")), m)
               for tid, cmd, role, m in threads]
    by = {}
    for _, _, role, m in threads:
        by.setdefault(role, []).append(m)
    note = (f"{rel} (sha256 {sha256_file(path)[:12]}), window "
            + (f"t_s {t0}..{t1}" if t0 is not None and t1 is not None
               else "whole file (classify_window missing)")
            + ("; reader inferred as the busiest kraken2 thread" if inferred else ""))
    return by, note


def reading_r3(run, settings):
    ref = best(settings, "I0")
    if ref is None:
        return "undecided", "no usable I0 point"
    by, note = read_pidstat(run, ref.rep)
    if by is None:
        return "undecided", f"I0's best setting {ref.label()} ({ref.rep['_src']}): {note}"
    rd, wk = by.get("kraken2_reader"), by.get("kraken2_worker")
    if not rd or not wk:
        return "undecided", f"{note}: no kraken2_reader or no kraken2_worker thread"
    rmax, wmean = max(rd), statistics.mean(wk)
    txt = (f"{ref.label()} ({ref.rep['_src']}; {note}): reader {rmax:.1f}% of one CPU "
           f"(threshold >= {READER_SAT:.0f}%), worker mean {wmean:.1f}% over {len(wk)} threads "
           f"(threshold < {WORKER_IDLE:.0f}%)")
    if rmax >= READER_SAT and wmean < WORKER_IDLE:
        return "applies", txt + ": upstream's ceiling is its serial parse and batch"
    return "does not apply", txt


def reading_r4(settings):
    i4 = [s for s in settings if s.arm == "I4"]
    if not i4:
        return "undecided", "no usable I4 point"
    b4 = min(i4, key=lambda s: (s.wall, s.src))
    ref = best(settings, "I2", p=b4.p, threads=b4.threads, thp=b4.thp)
    if ref is None:
        return "undecided", f"no I2 point at I4's setting ({b4.label()}, {b4.src})"
    d, tol, noise, v = compare(b4, ref, WITHIN, "within")
    txt = cmp_text(b4, ref, d, tol, noise)
    if v == "unresolved":
        return "undecided", "spread exceeds 5%, the lever cannot be resolved: " + txt
    if abs(d) <= WITHIN:
        return "measured", f"BGZF lever value {pct(-d)} of I2's wall, within 5% (no measurable " \
                          f"value): {txt}"
    return "measured", f"BGZF lever value {pct(-d)} of I2's wall (I4 " \
                      f"{'faster' if d < 0 else 'slower'}, beyond 5%): {txt}"


# ---------------------------------------------------------------------------------------------
# Rendering

def r4_value(r4):
    v = r4[1].split("BGZF lever value ", 1)[1].split(" of I2", 1)[0]
    return v + (" (within 5%)" if "within 5%" in r4[1] else " (beyond 5%)")


def bar(cores, scale):
    n = int(round(cores * scale))
    return "#" * n if n else ("." if cores > 0 else "")


def cpu_table(run, settings, out):
    out.append("| arm | best setting | role | threads | CPU (cores) | share | bar |")
    out.append("|---|---|---|---|---|---|---|")
    notes, rows = [], []
    for arm in ARMS:
        b = best(settings, arm)
        if b is None:
            continue
        by, note = read_pidstat(run, b.rep)
        if by is None:
            rows.append((arm, b, None, note))
            continue
        rows.append((arm, b, by, note))
    mx = max([sum(v) / 100 for _, _, by, _ in rows if by for v in by.values()] or [1])
    scale = 40.0 / mx if mx else 1
    for arm, b, by, note in rows:
        lab = f"{b.label()} ({b.rep['_src']})"
        if by is None:
            out.append(f"| {arm} | {lab} | {MISSING} | | | | |")
            notes.append(f"- {arm}: {note}")
            continue
        tot = sum(sum(v) for v in by.values()) / 100
        for role in ROLES:
            if role not in by:
                continue
            c = sum(by[role]) / 100
            out.append(f"| {arm} | {lab} | {role} | {len(by[role])} | {c:.2f} | "
                       f"{100 * c / tot:.0f}% | `{bar(c, scale)}` |")
        notes.append(f"- {arm}: {note}")
    out.append("")
    out.append(f"Bar: one `#` = {1 / scale:.2f} cores. CPU = the sum over the role's threads of "
               "their mean %CPU over the classify window, / 100. Sources:")
    out.extend(notes)


def render(run, out_path):
    manifest = load_manifest(run)
    points = load_points(run)
    defects = []
    usable = validate(points, manifest, defects)
    law1_lines = []
    bad_ids = law1(usable, defects, law1_lines)
    used = [p for p in usable if p["point_id"] not in bad_ids]

    inst = manifest.get("instance") or {}
    price = manifest.get("truffle_price_usd_per_hour")
    billed, cost = manifest.get("billed_seconds"), manifest.get("cost_usd")
    up = manifest.get("upstream") or {}
    o = []
    o.append(f"## Input-path sweep (#90): `{os.path.basename(os.path.normpath(run))}`")
    o.append("")
    o.append("Generated by `scripts/lib/inputpath_report.py` at commit "
             f"`{_git_head()[:12]}` from this run dir only.")
    o.append("")
    o.append("| field | value | source |")
    o.append("|---|---|---|")
    for k, v, s in [
        ("commit", f"`{manifest.get('commit', MISSING)}`", ".commit"),
        ("upstream pin", f"`{up.get('pin', MISSING)}` (`{up.get('describe', MISSING)}`)",
         ".upstream"),
        ("instance", f"{inst.get('count', MISSING)} x `{inst.get('type', MISSING)}`, AMI "
         f"`{inst.get('ami', MISSING)}`", ".instance"),
        ("region / AZ", f"{manifest.get('region', MISSING)} / {inst.get('az', MISSING)}",
         ".region, .instance.az"),
        ("truffle price at launch", f"${fmt(price, 4)}/h", ".truffle_price_usd_per_hour"),
        ("billed seconds", fmt(billed), ".billed_seconds"),
        ("session cost", f"${fmt(cost, 4)} ({manifest.get('cost_basis', MISSING)})",
         ".cost_usd, .cost_basis"),
    ]:
        o.append(f"| {k} | {v} | manifest.json {s} |")
    o.append("")
    nsk = sum(1 for p in points if p.get("status") == "skipped")
    o.append(f"Points: {len(points)} records in out/points.jsonl; {len(used)} used, {nsk} "
             f"skipped, {len(points) - len(used) - nsk} excluded as defects.")
    o.append("")

    cost_basis = ("$/run = truffle price at launch (manifest.json .truffle_price_usd_per_hour) x "
                  "the point's median wall_s / 3600: the point's wall-second share of the "
                  "session at the launch price. Compute only; the session's DB load, setup and "
                  "idle time are not spread over the points.")
    if price is not None and billed and cost is not None:
        implied = price * billed / 3600
        if abs(implied - cost) > 0.01 * max(cost, 1e-9):
            cost_basis += (f" Note: manifest cost_usd {cost:.4f} differs from price x billed "
                           f"{implied:.4f} by more than 1%.")
    walls = sum(float(p["wall_s"]) for p in used)
    if billed:
        cost_basis += (f" The used points' walls sum to {walls:.0f} s of {billed} billed s "
                       f"({100 * walls / billed:.0f}%).")

    summary_rows = []
    families = sorted({p["family"] for p in used})
    readings_all = []
    for fam in families:
        fp = [p for p in used if p["family"] == fam]
        o.append(f"### Family `{fam}`")
        o.append("")
        for eng, acc in sorted({(p["engine"], accession(p)) for p in fp}):
            gp = [p for p in fp if p["engine"] == eng and accession(p) == acc]
            groups = {}
            for p in gp:
                groups.setdefault(setting_key(p), []).append(p)
            settings = [Setting(v) for v in groups.values()]
            settings.sort(key=lambda s: (ARMS.index(s.arm), s.p or 0, s.threads, s.chunk or 0,
                                         s.thp, s.pipe or 0))
            o.append(f"#### `{eng}`, input `{acc}` ({role_of(gp[0])})")
            o.append("")
            o.append(f"Wall, MB/s, reads/s and RSS from out/points.jsonl at the lines in `src` "
                     f"(median over reps; range when n > 1). {cost_basis}")
            o.append("")
            o.append("| arm | p | threads | chunk MiB | thp | pipe bytes | fan-out | n | "
                     "wall s | FASTQ MB/s | classify reads/s | $/run (price x wall) | "
                     "RSS kraken2 KiB | RSS rapidgzip KiB | src |")
            o.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
            for s in settings:
                wall = f"{s.wall:.1f}" + (f" [{s.wmin:.1f}-{s.wmax:.1f}]" if s.n > 1 else "")
                usd = s.wall * price / 3600 if price is not None else None
                o.append("| " + " | ".join([
                    s.arm, na_or(s.p, s.arm), str(s.threads), na_or(s.chunk, s.arm), s.thp,
                    na_or(s.pipe, s.arm, {"I1", "I2", "I3", "I4"}),
                    na_or(s.fanout, eng, {"ours"}), str(s.n), wall, fmt(s.mbps()),
                    fmt(s.rps(), 0), MISSING if usd is None else f"{usd:.4f}",
                    fmt(s.rss("kraken2")), na_or(s.rss("rapidgzip"), s.arm), s.src]) + " |")
                summary_rows.append([fam, eng, acc, s.arm, fmt(s.p), str(s.threads), fmt(s.chunk),
                                     s.thp, fmt(s.pipe), str(s.n), f"{s.wall:.3f}",
                                     f"{s.wmin:.3f}", f"{s.wmax:.3f}", fmt(s.mbps(), 3),
                                     MISSING if usd is None else f"{usd:.6f}", s.src])
            o.append("")
            o.append(f"CPU attribution per arm at its best setting (lowest median wall):")
            o.append("")
            cpu_table(run, settings, o)
            o.append("")
            r1 = reading_r1(settings)
            r2 = reading_r2(settings)
            r3 = reading_r3(run, settings)
            r4 = reading_r4(settings)
            o.append("Readings (rules: docs/inputpath.md, \"Reading rules\"; lines cite "
                     "out/points.jsonl):")
            o.append("")
            o.append(f"- R1 (I1 within 5% of I0 -> strike single-stream gzip): **{r1[0]}**: "
                     f"{r1[1]}")
            o.append(f"- R2 (I2/I3 reaches I0 at some p -> smallest p): **{r2[0]}**: {r2[1]}"
                     + (f". {r2[2]}" if r2[2] else ""))
            o.append(f"- R3 (I0 limited by a saturated reader while workers idle): "
                     f"**{r3[0]}**: {r3[1]}")
            o.append(f"- R4 (I4 vs I2: BGZF lever): **{r4[0]}**: {r4[1]}")
            o.append("")
            app = [n for n, r in (("R1", r1), ("R2", r2), ("R3", r3)) if r[0] == "applies"]
            und = [n for n, r in (("R1", r1), ("R2", r2), ("R3", r3), ("R4", r4))
                   if r[0] == "undecided"]
            line = (f"**Reading ({fam}, {eng}, {acc}):** "
                    + (", ".join(app) + " appl" + ("ies" if len(app) == 1 else "y")
                       if app else "none applies")
                    + (f"; R4 measured: BGZF lever {r4_value(r4)}" if r4[0] == "measured"
                       else "")
                    + (f"; undecided: {', '.join(und)}" if und else "") + ".")
            o.append(line)
            o.append("")
            readings_all.append(line)

    o.append("### Pins")
    o.append("")
    rg = {}
    for p in used:
        if p["arm"] in RG_ARMS:
            r = p.get("rapidgzip")
            k = (json.dumps(r, sort_keys=True) if isinstance(r, dict) else MISSING)
            rg.setdefault(k, []).append(p["_src"])
    for k, srcs in sorted(rg.items()):
        o.append(f"- rapidgzip {k} at out/points.jsonl {','.join(srcs)}")
    for fld in ("index_sha256", "bgzf_sha256"):
        arm = "I3" if fld == "index_sha256" else "I4"
        vals = {}
        for p in used:
            if p["arm"] == arm:
                vals.setdefault(p.get(fld) or MISSING, []).append(p["_src"])
        for v, srcs in sorted(vals.items()):
            o.append(f"- {arm} {fld} `{v}` at out/points.jsonl {','.join(srcs)}")
    o.append("")

    o.append("### Law 1")
    o.append("")
    o.extend(law1_lines)
    o.append("")
    sk = [p for p in points if p.get("status") == "skipped"]
    if sk:
        o.append("Skipped (recorded, never used):")
        o.append("")
        for p in sk:
            idn = p.get("identity") or {}
            o.append(f"- {p.get('point_id', MISSING)} (out/points.jsonl:{p['_src']}): "
                     f"{p.get('arm', MISSING)} p{p.get('p', MISSING)} t{p.get('threads', MISSING)}"
                     f"; identity rg_exit {idn.get('rg_exit', MISSING)}, ok "
                     f"{idn.get('ok', MISSING)}; {p.get('note', MISSING)}")
        o.append("")
    if defects:
        o.append(f"**{len(defects)} DEFECT line(s):**")
        o.append("")
        o.extend(f"- {d}" for d in defects)
    else:
        o.append("No DEFECT: every used point's output and report sha256 match I0's.")
    o.append("")
    o.append("### Summary")
    o.append("")
    o.extend(f"- {r}" for r in readings_all)
    if not readings_all:
        o.append("- No usable points: every reading undecided.")

    text = "\n".join(o) + "\n"
    sys.stdout.write(text)
    tables = os.path.join(run, "tables")
    os.makedirs(tables, exist_ok=True)
    out_path = out_path or os.path.join(tables, "inputpath-report.md")
    with open(out_path, "w") as f:
        f.write(text)
    with open(os.path.join(tables, "inputpath-summary.tsv"), "w") as f:
        f.write("\t".join(["family", "engine", "accession", "arm", "p", "threads", "chunk_mib",
                           "thp", "pipe_bytes", "n", "wall_s_median", "wall_s_min", "wall_s_max",
                           "fastq_mb_per_s", "usd_price_x_wall", "src_points_jsonl"]) + "\n")
        for r in summary_rows:
            f.write("\t".join(r) + "\n")
    return 1 if defects else 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) >= 2 else 2
    run = argv[1].rstrip("/")
    if not os.path.isdir(run):
        die(f"{run}: no run dir")
    out = argv[2] if len(argv) > 2 and argv[2] else None
    return render(run, out)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
