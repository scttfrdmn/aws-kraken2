#!/usr/bin/env python3
"""make g3-ladder-model (#52; docs/ladder.md, "Modelled values"): the modelled stock T1 point at a
cohort that is not measured (Scott, #25: "At c100 threads = vCPUs is measured. T1 is modelled from
c10's per-thread rate and flagged"), derived from the record only.

  ladder_model.py [--results results] [--levers scripts/g3/ladder.levers.tsv] [--rung S0-T1]
                  [--from-cohort 10] [--to-cohort 100] [--target-ref @PRJNA398089:1-100]
                  [--out results/g3/ladder-modelled.tsv]

Model, per measured run of RUNG at FROM-COHORT (cold ladder runs that pass ladder_tables'
validation):
  P = the run's pairs (sum of its lad-sample pairs); S = its per-sample seconds (sum over its
  lad-sample lines of every phases value); per-thread rate r = P / S (T1: one thread);
  fixed F = wall - S (boot, setup, staging: everything not per sample).
  wall(TO) = F + P_target / r, where P_target = the read_count sum of TARGET-REF's ranks in the
  recorded runs.tsv; billed(TO) = wall(TO) x price/h x nodes / 3600.
The value written is the median over the measured runs. Every row's source cites this script's
commit and every file it read as path=sha256 (ladder_tables.py refuses a row whose files do not
check). The rows are flagged as modelled wherever they are used.
"""
import argparse
import csv
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ladder_tables as lt  # noqa: E402

HEAD = ["arm", "rung", "cohort", "axis", "value", "basis", "source"]


def target_pairs(repo, ref, rd):
    m = re.match(r"^@([A-Za-z0-9_.-]+):(\d+)-(\d+)$", ref)
    if not m:
        raise SystemExit(f"ladder_model: --target-ref {ref!r} is not @<project>:<a>-<b>")
    rel = f"results/cohort/{m.group(1)}/runs.tsv"
    p = os.path.join(repo, rel)
    if not os.path.exists(p):
        raise SystemExit(f"ladder_model: {rel} not found")
    a, b = int(m.group(2)), int(m.group(3))
    rows = [r for r in csv.DictReader(rd.text(p).splitlines(), delimiter="\t")
            if (r.get("rank") or "").isdigit() and a <= int(r["rank"]) <= b]
    if len(rows) != b - a + 1 or any(not (r.get("read_count") or "").isdigit() for r in rows):
        raise SystemExit(f"ladder_model: {rel}: ranks {a}-{b} need {b - a + 1} rows with a read_count")
    return sum(int(r["read_count"]) for r in rows), p


def model(results, levers_path, rung, c_from, c_to, ref, git_commit=None):
    """(rows, message). rows: the wall_s and billed_usd rows, or [] if no run qualifies."""
    repo = os.path.dirname(os.path.abspath(results))
    rd = lt.Reader()
    levers = lt.load_levers(levers_path, rd)
    runs = lt.discover(results, rd)
    lt.validate(runs, levers, [])
    use = [r for r in runs if r["params"]["rung"] == rung and r["params"].get("cohort") == c_from
           and r["params"]["run_kind"] == "ladder" and r["params"]["state"] == "cold" and not r["exclude"]]
    walls, bills, ids, cite = [], [], [], []
    ptar, runs_tsv = target_pairs(repo, ref, rd)
    for r in use:
        P = sum(s["pairs"] for s in r["samples"])
        S = sum(v for s in r["samples"] for v in s["phases"].values())
        if not S or r["wall_s"] is None or r["price"] is None:
            continue
        w = (r["wall_s"] - S) + ptar / (P / S)
        walls.append(w)
        bills.append(w * r["price"] * r["nodes"] / 3600.0)
        ids.append(r["run_id"])
        d = os.path.abspath(r["dir"])
        members = [d] + [os.path.join(os.path.dirname(d), x) for x in os.listdir(os.path.dirname(d))
                         if x.startswith(os.path.basename(d) + "-r")] if r["kind"] == "cohort" else [d]
        for p, (_, sha) in sorted(rd.files.items()):
            if any(p.startswith(m + os.sep) for m in members):
                cite.append(f"{os.path.relpath(p, repo)}={sha}")
    if not walls:
        return [], f"no cold, valid {rung} ladder runs at c{c_from} under {results}"
    rs_sha = rd.files[os.path.abspath(runs_tsv)][1]
    cite.append(f"{os.path.relpath(runs_tsv, repo)}={rs_sha}")
    commit = git_commit if git_commit is not None else lt.git("rev-parse", "HEAD")
    src = (f"scripts/lib/ladder_model.py {commit or 'unknown'}: c{c_from} {rung} runs {', '.join(ids)}; target {ref} "
           f"({ptar} pairs) | " + " ".join(cite))
    basis = (f"c{c_from} {rung} per-thread rate: wall = (wall - per-sample s) + c{c_to} pairs / (pairs per per-sample s); "
             f"median of {len(walls)} run(s)")
    arm = (levers.get(rung) or {}).get("arm", rung[:1])
    rows = [[arm, rung, c_to, "wall_s", f"{statistics.median(walls):.3f}", basis, src],
            [arm, rung, c_to, "billed_usd", f"{statistics.median(bills):.6f}", basis + "; x price/h x nodes / 3600", src]]
    return rows, f"{len(walls)} run(s): wall {statistics.median(walls):.1f} s, billed ${statistics.median(bills):.4f}"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", default=os.path.join(lt.ROOT, "results"))
    ap.add_argument("--levers", default=os.path.join(lt.ROOT, "scripts", "g3", "ladder.levers.tsv"))
    ap.add_argument("--rung", default="S0-T1")
    ap.add_argument("--from-cohort", type=int, default=10)
    ap.add_argument("--to-cohort", type=int, default=100)
    ap.add_argument("--target-ref", default="@PRJNA398089:1-100")
    ap.add_argument("--out", default=None, help="default <results>/g3/ladder-modelled.tsv")
    a = ap.parse_args(argv)
    rows, msg = model(a.results, a.levers, a.rung, a.from_cohort, a.to_cohort, a.target_ref)
    if not rows:
        print(f"ladder_model: {msg}; nothing written", file=sys.stderr)
        return 2
    out = a.out or os.path.join(a.results, "g3", "ladder-modelled.tsv")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(HEAD)
        w.writerows(rows)
    print(f"ladder_model: {a.rung} c{a.to_cohort} from c{a.from_cohort}: {msg} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
