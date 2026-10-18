#!/usr/bin/env python3
"""make inputpath-report-test (in make test): scripts/lib/inputpath_report.py on a synthetic run
dir (#90; docs/inputpath.md, "Records and report").

SYNTHETIC DATA, unit test only (Law 3): scripts/tests/fixtures/inputpath/synthetic-run/ is
written by build() below (`--write-fixture` rewrites it; the test fails if the checked-in copy
drifts from build()). It is never under results/ and no number in it is a measurement.

Cases (each on a scratch copy):
  - base: exit 0; R1 applies, R2 applies at p=4 (I2, the smallest p, p=2 does not reach), R3
    applies (reader 96% of a CPU, workers 40%), R4 applies (BGZF value beyond 5%); a skipped
    point (rapidgzip exit 139, identity not ok) is listed and unused; missing optional fields
    print "missing"; the inferred-reader and whole-file-window notes appear; SE input: R3 and R4
    undecided (no pidstat, no I4); $/run = price x wall; OUT= is honoured.
  - Law 1: one I2 point with a different output sha256 -> DEFECT (Law 1) line, exit 1, excluded.
  - R1 does not apply (I1 t48 at 140 s); R2 does not apply (I2/I3 +20 s);
  - noise: I0 t48 reps 110/131 s -> spread > 5% -> R1 and R2 undecided;
  - R3 does not apply (workers at 85%); R4 undecided (no I4);
  - a used point whose identity failed -> DEFECT (identity), exit 1;
  - an ok point missing report_sha256 -> DEFECT (record), exit 1;
  - unfinalised manifest -> exit 2.
Run from the repo root (make test does)."""
import copy
import filecmp
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCRIPT = os.path.join(ROOT, "scripts", "lib", "inputpath_report.py")
FIXTURE = os.path.join(ROOT, "scripts", "tests", "fixtures", "inputpath", "synthetic-run")
PRICE = 2.5466


def h(s):
    return hashlib.sha256(s.encode()).hexdigest()


OUT_PE, REP_PE = h("synthetic-output-PE"), h("synthetic-report-PE")
OUT_SE, REP_SE = h("synthetic-output-SE"), h("synthetic-report-SE")
GZ_PE = h("synthetic-fastq-PE")


def manifest():
    return {
        "_synthetic": "SYNTHETIC fixture for scripts/tests/inputpath_report_test.py; not a run",
        "gate": "inputpath", "run_id": "synthetic-run",
        "commit": "0" * 40, "tree_dirty": False,
        "upstream": {"pin": "2731b35f7abb26ec926517274f3d87e78d42fd76",
                     "describe": "2.17.2-20-g2731b35"},
        "region": "us-west-2",
        "instance": {"type": "c8g.16xlarge", "count": 1, "ami": "ami-00000000000000000",
                     "az": "us-west-2b", "lifecycle": "on-demand"},
        "truffle_price_usd_per_hour": PRICE,
        "billed_seconds": 3600, "cost_usd": PRICE,
        "cost_basis": "on-demand truffle price x (terminated_at - launch_time)",
        "start": "2026-10-18T00:00:00Z", "stop": "2026-10-18T01:00:00Z",
        "manifest_finalised_at": "2026-10-18T01:01:00Z",
    }


def point(pid, arm, threads, wall, acc="SYNTHETIC-PE1", p=None, chunk=None, thp="always",
          rep=1, pidstat=None, **kw):
    pe = acc.endswith("PE1")
    o = {"schema": "inputpath-point/1", "point_id": pid, "rep": rep, "arm": arm,
         "engine": "upstream", "family": "c8g", "instance_type": "c8g.16xlarge",
         "db": "k2_standard_08_GB_20260626", "p": p, "threads": threads, "chunk_mib": chunk,
         "thp": thp, "pipe_bytes": 1048576 if arm != "I0" else None,
         "input": {"role": "paired" if pe else "single", "accession": acc,
                   "mates": [{"mate": m, "s3_key": f"aws-kraken2/synthetic/{acc}_{m}.fastq.gz",
                              "sha256": h(f"{acc}-{m}")} for m in ((1, 2) if pe else (1,))]},
         "fastq_bytes": 6_000_000_000 if pe else 2_000_000_000,
         "wall_s": wall, "classify_reads_per_s": round((20e6 if pe else 8e6) / wall, 1) if wall else None,
         "classify_window": {"t0": 1, "t1": 5},
         "peak_rss_kb": {"kraken2": 8_500_000} | ({"rapidgzip": 400_000} if arm in
                                                  ("I2", "I3", "I4") else {}),
         "output_sha256": OUT_PE if pe else OUT_SE, "report_sha256": REP_PE if pe else REP_SE,
         "status": "ok", "note": "SYNTHETIC"}
    if arm in ("I2", "I3", "I4"):
        o["rapidgzip"] = {"version": "0.14.5", "build": "pypi", "isal": True}
        o["identity"] = {"gz_sha256": GZ_PE, "rg_sha256": GZ_PE, "rg_exit": 0, "ok": True}
    if arm == "I3":
        o["index_sha256"] = h("synthetic-index")
    if arm == "I4":
        o["bgzf_sha256"] = h("synthetic-bgzf")
    if pidstat:
        o["pidstat_csv"] = f"out/pidstat/{pidstat}.csv"
    o.update(kw)
    return o


def base_points():
    P = point
    pts = [
        P("I0-t16", "I0", 16, 300.0), P("I0-t32", "I0", 32, 160.0),
        P("I0-t48-r1", "I0", 48, 120.0, pidstat="I0-t48-r1"),
        P("I0-t48-r2", "I0", 48, 121.0, rep=2),
        P("I0-t48-never", "I0", 48, 130.0, thp="never"),
        P("I1-t16", "I1", 16, 305.0), P("I1-t32", "I1", 32, 165.0),
        P("I1-t48", "I1", 48, 124.0, pidstat="I1-t48"),
        P("I2-p2-t48-r1", "I2", 48, 150.0, p=2, chunk=4),
        P("I2-p2-t48-r2", "I2", 48, 151.0, p=2, chunk=4, rep=2),
        P("I2-p4-t48-r1", "I2", 48, 121.0, p=4, chunk=4, pidstat="I2-p4-t48-r1"),
        P("I2-p4-t48-r2", "I2", 48, 122.0, p=4, chunk=4, rep=2),
        P("I2-p4-t48-c8", "I2", 48, 122.5, p=4, chunk=8),
        P("I2-p4-t48-c16", "I2", 48, 123.0, p=4, chunk=16),
        P("I2-p8-t48-r1", "I2", 48, 122.0, p=8, chunk=4),
        P("I2-p8-t48-r2", "I2", 48, 122.5, p=8, chunk=4, rep=2),
        P("I2-p8-t48-r3", "I2", 48, 0.0, p=8, chunk=4, rep=3, status="skipped",
          identity={"gz_sha256": GZ_PE, "rg_sha256": None, "rg_exit": 139, "ok": False},
          note="SYNTHETIC: rapidgzip SIGSEGV in the identity step; recorded, never used"),
        P("I2-p16-t48-r1", "I2", 48, 123.0, p=16, chunk=4),
        P("I2-p16-t48-r2", "I2", 48, 123.5, p=16, chunk=4, rep=2),
        P("I3-p4-t48", "I3", 48, 121.0, p=4, pidstat="I3-p4-t48"),
        P("I4-p4-t48", "I4", 48, 115.0, p=4, chunk=4, pidstat="I4-p4-t48"),
        P("SE-I0-t48", "I0", 48, 60.0, acc="SYNTHETIC-SE1"),
        P("SE-I1-t48", "I1", 48, 61.0, acc="SYNTHETIC-SE1"),
        P("SE-I2-p4-t48", "I2", 48, 60.5, acc="SYNTHETIC-SE1", p=4, chunk=4),
    ]
    for p in pts:  # optional fields left out on purpose: shown as "missing"
        if p["point_id"] == "I3-p4-t48":
            for k in ("peak_rss_kb", "chunk_mib", "pipe_bytes", "fastq_bytes"):
                del p[k]
        if p["point_id"] == "I4-p4-t48":
            del p["classify_window"]
    return pts


# pidstat: (reader %, worker %, decoder command, decoder threads, decoder %, roles on kraken2)
PIDSTAT = {
    "I0-t48-r1": (96, 40, None, 0, 0, True),
    "I1-t48": (97, 38, "gzip", 2, 99, True),
    "I2-p4-t48-r1": (92, 41, "rapidgzip", 8, 55, True),
    "I3-p4-t48": (92, 41, "rapidgzip", 8, 45, False),  # no kraken2 roles: reader inferred
    "I4-p4-t48": (91, 42, "rapidgzip", 8, 35, True),
}


def pidstat_csv(reader, worker, dec, ndec, decpct, roles, threads=48):
    rows = ["t_s,tgid,tid,command,role,cpu_pct"]
    for t in range(6):
        if t == 0:
            rr, ww = 5, 0  # before the classify window: excluded
        else:
            rr, ww = reader, worker
        rows.append(f"{t},1000,1000,kraken2,{'kraken2_reader' if roles else ''},{rr}")
        for i in range(1, threads):
            rows.append(f"{t},1000,{1000 + i},kraken2,{'kraken2_worker' if roles else ''},{ww}")
        for i in range(ndec):
            rows.append(f"{t},{2000 + i // 4},{2000 + i},{dec},{dec},{decpct if t else 0}")
    return "\n".join(rows) + "\n"


def build(d, points=None, pidstat=None):
    os.makedirs(os.path.join(d, "out", "pidstat"), exist_ok=True)
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(manifest(), f, indent=2, sort_keys=True)
        f.write("\n")
    with open(os.path.join(d, "out", "points.jsonl"), "w") as f:
        for p in (points if points is not None else base_points()):
            f.write(json.dumps(p, sort_keys=True) + "\n")
    for name, args in (pidstat or PIDSTAT).items():
        with open(os.path.join(d, "out", "pidstat", f"{name}.csv"), "w") as f:
            f.write(pidstat_csv(*args))
    with open(os.path.join(d, "SYNTHETIC"), "w") as f:
        f.write("Synthetic fixture for scripts/tests/inputpath_report_test.py (Law 3: unit test "
                "only). Regenerate: python3 scripts/tests/inputpath_report_test.py "
                "--write-fixture\n")


FAILS = []


def check(name, cond, detail=""):
    if not cond:
        FAILS.append(f"{name}: {detail}")
        print(f"FAIL {name} {detail}")
    else:
        print(f"ok   {name}")


def run(d, out=None):
    args = [sys.executable, SCRIPT, d] + ([out] if out else [])
    r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def reading(text, acc, r):
    for line in text.splitlines():
        if line.startswith(f"- {r} ") and f"`{acc}`" in section(text, acc):
            pass
    sec = section(text, acc)
    for line in sec.splitlines():
        if line.startswith(f"- {r} "):
            return line
    return ""


def section(text, acc):
    start = text.find(f"input `{acc}`")
    end = text.find("#### ", start + 1)
    end = text.find("### Pins") if end < 0 else end
    return text[start:end]


def scratch(tmp, name, points=None, pidstat=None):
    d = os.path.join(tmp, name)
    build(d, points, pidstat)
    return d


def main():
    if "--write-fixture" in sys.argv:
        shutil.rmtree(FIXTURE, ignore_errors=True)
        build(FIXTURE)
        print(f"wrote {FIXTURE}")
        return 0
    tmp = tempfile.mkdtemp(prefix="inputpath-test-")
    try:
        # The checked-in fixture is build()'s output.
        ref = scratch(tmp, "ref")
        cmp = filecmp.dircmp(FIXTURE, ref)
        drift = cmp.left_only + cmp.right_only + cmp.diff_files
        for sub in ("out", os.path.join("out", "pidstat")):
            c = filecmp.dircmp(os.path.join(FIXTURE, sub), os.path.join(ref, sub))
            drift += c.left_only + c.right_only + c.diff_files
        check("fixture matches build()", not drift, str(drift))

        # base
        d = os.path.join(tmp, "base")
        shutil.copytree(FIXTURE, d)
        out = os.path.join(tmp, "base-out.md")
        rc, so, se = run(d, out)
        check("base exit 0", rc == 0, f"rc={rc} {se}")
        check("base OUT written", os.path.isfile(out) and open(out).read() == so)
        check("base summary tsv", os.path.isfile(os.path.join(d, "tables",
                                                              "inputpath-summary.tsv")))
        r = reading(so, "SYNTHETIC-PE1", "R1")
        check("R1 applies", "**applies**" in r and "all 3 matched setting(s)" in r, r)
        r = reading(so, "SYNTHETIC-PE1", "R2")
        check("R2 applies at p=4", "**applies**" in r and "I2 reaches I0 at p=4" in r
              and "Pipe cost (I2 at its best p vs I0): +0.8%" in r and "can wait" in r, r)
        r = reading(so, "SYNTHETIC-PE1", "R3")
        check("R3 applies", "**applies**" in r and "reader 96.0%" in r
              and "worker mean 40.0% over 47 threads" in r, r)
        r = reading(so, "SYNTHETIC-PE1", "R4")
        check("R4 value beyond 5%", "**measured**" in r and "+5.3%" in r and "beyond 5%" in r, r)
        r = reading(so, "SYNTHETIC-SE1", "R3")
        check("SE R3 undecided (no pidstat)", "**undecided**" in r and "pidstat_csv missing" in r,
              r)
        r = reading(so, "SYNTHETIC-SE1", "R4")
        check("SE R4 undecided (no I4)", "**undecided**" in r and "no usable I4" in r, r)
        check("summary line", "**Reading (c8g, upstream, SYNTHETIC-PE1):** R1, R2, R3 apply; R4 measured: BGZF lever "
              "+5.3% (beyond 5%)."
              in so)
        check("skipped listed", "I2-p8-t48-r3 (out/points.jsonl:L17)" in so and
              "rg_exit 139" in so)
        check("skipped not used", "I2 | 8 | 48 | 4 | always | 1048576 | n/a | 2 |" in so)
        check("missing optional", "| I3 | 4 | 48 | missing | always | missing |" in so, "")
        check("inferred reader", "reader inferred as the busiest kraken2 thread" in so)
        check("whole-file window", "whole file (classify_window missing)" in so)
        usd = 120.5 * PRICE / 3600
        check("$/run = price x wall", f"| {usd:.4f} |" in so, f"{usd:.4f}")
        check("cost basis stated", "$/run = truffle price at launch" in so)
        check("no DEFECT", "No DEFECT" in so and "DEFECT (" not in so)
        check("pidstat cited with sha256", "out/pidstat/I0-t48-r1.csv (sha256 " in so)

        # Law 1 mismatch
        pts = base_points()
        for p in pts:
            if p["point_id"] == "I2-p16-t48-r1":
                p["output_sha256"] = h("different")
        d = scratch(tmp, "law1", pts)
        rc, so, se = run(d)
        check("Law 1 exit 1", rc == 1, f"rc={rc}")
        check("Law 1 DEFECT line", "DEFECT (Law 1) I2-p16-t48-r1 (out/points.jsonl:L18): output "
              "sha256 differ from I0" in so, so[-800:])
        check("Law 1 point excluded", "| I2 | 16 | 48 | 4 | always | 1048576 | n/a | 1 |" in so)

        # R1 does not apply
        pts = base_points()
        for p in pts:
            if p["point_id"] == "I1-t48":
                p["wall_s"] = 140.0
        rc, so, _ = run(scratch(tmp, "r1no", pts))
        r = reading(so, "SYNTHETIC-PE1", "R1")
        check("R1 does not apply", "**does not apply**" in r, r)

        # R2 does not apply
        pts = base_points()
        for p in pts:
            if p["arm"] in ("I2", "I3") and p["input"]["accession"] == "SYNTHETIC-PE1":
                p["wall_s"] += 20
        rc, so, _ = run(scratch(tmp, "r2no", pts))
        r = reading(so, "SYNTHETIC-PE1", "R2")
        check("R2 does not apply", "**does not apply**" in r, r)

        # noise > 5%: R1 and R2 undecided
        pts = base_points()
        for p in pts:
            if p["point_id"] == "I0-t48-r1":
                p["wall_s"] = 110.0
            if p["point_id"] == "I0-t48-r2":
                p["wall_s"] = 131.0
            if p["point_id"] == "I1-t48":
                p["rep"] = 1
        pts.append(point("I1-t48-r2", "I1", 48, 124.5, rep=2))
        rc, so, _ = run(scratch(tmp, "noise", pts))
        r1, r2 = reading(so, "SYNTHETIC-PE1", "R1"), reading(so, "SYNTHETIC-PE1", "R2")
        check("noise R1 undecided", "**undecided**" in r1 and "cannot be resolved" in r1, r1)
        check("noise R2 undecided", "**undecided**" in r2, r2)

        # R3 does not apply
        ps = dict(PIDSTAT)
        ps["I0-t48-r1"] = (96, 85, None, 0, 0, True)
        rc, so, _ = run(scratch(tmp, "r3no", None, ps))
        r = reading(so, "SYNTHETIC-PE1", "R3")
        check("R3 does not apply", "**does not apply**" in r and "worker mean 85.0%" in r, r)

        # R4 undecided
        pts = [p for p in base_points() if p["arm"] != "I4"]
        rc, so, _ = run(scratch(tmp, "r4und", pts))
        r = reading(so, "SYNTHETIC-PE1", "R4")
        check("R4 undecided", "**undecided**" in r, r)

        # a used point whose identity failed
        pts = base_points()
        for p in pts:
            if p["point_id"] == "I2-p2-t48-r1":
                p["identity"] = {"gz_sha256": GZ_PE, "rg_sha256": h("x"), "rg_exit": 0,
                                 "ok": False}
        rc, so, _ = run(scratch(tmp, "ident", pts))
        check("identity DEFECT exit 1", rc == 1 and "DEFECT (identity) I2-p2-t48-r1" in so)

        # missing required field
        pts = base_points()
        del pts[0]["report_sha256"]
        rc, so, _ = run(scratch(tmp, "req", pts))
        check("missing required DEFECT", rc == 1 and "DEFECT (record) I0-t16" in so
              and "report_sha256" in so)

        # unfinalised manifest
        d = scratch(tmp, "unfin")
        m = json.load(open(os.path.join(d, "manifest.json")))
        del m["manifest_finalised_at"]
        json.dump(m, open(os.path.join(d, "manifest.json"), "w"))
        rc, so, se = run(d)
        check("unfinalised exit 2", rc == 2 and "not finalised" in se, se)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if FAILS:
        print(f"inputpath_report_test: {len(FAILS)} failure(s)")
        return 1
    print("inputpath_report_test: all ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
