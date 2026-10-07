#!/usr/bin/env python3
"""The G3 tidy table (#25, #26): every engine measurement of a run as rows.

  tidy.py member RUN_DIR      RUN_DIR/tables/tidy.tsv from RUN_DIR/out/rank*/eng-*.stderr
  tidy.py cohort COHORT_DIR   COHORT_DIR/tables/tidy.tsv (the members' rows, from cohort.json's
                              members) and COHORT_DIR/tables/rates.tsv (derived rates)

Rows: run_id, rank, invocation, kind, batch, sample, metric, value.
  kind phase      an ak2-timing line: metric = the phase, value = seconds (and <phase>.start_s)
  kind engine.X   an ak2-engine X line (shard, route, worker, node, load, rendezvous): its
                  key/value pairs (the shard line's leading index is metric "index")
  kind sample     an ak2-sample line (cohort mode): its key/value pairs, batch and sample set
Only these lines are read; nothing is typed in.

rates.tsv, one row per invocation (all ranks): nodes, sequences (pairs), load GB/s per node
(mean, min), worker CPU-seconds per pair and pairs per worker-CPU-second, lookups per pair and
routed lookup bytes per pair per node (12 bytes per remote lookup: 8 out, 4 back), read_s per
pair (the producer's cut, decompression included), and the emitter's emit and close seconds.
"""
import csv, glob, json, os, re, sys

HEAD = ["run_id", "rank", "invocation", "kind", "batch", "sample", "metric", "value"]


def pairs(fields):
    out = []
    for i in range(0, len(fields) - 1, 2):
        out.append((fields[i], fields[i + 1]))
    return out


def member_rows(run_dir):
    run_id = os.path.basename(os.path.normpath(run_dir))
    rows = []
    for path in sorted(glob.glob(os.path.join(run_dir, "out", "rank*", "eng-*.stderr"))):
        m = re.search(r"rank(\d+)/eng-(.+)\.stderr$", path)
        rank, inv = m.group(1), m.group(2)
        for line in open(path, errors="replace"):
            f = line.rstrip("\n").split("\t")
            if f[0] == "ak2-timing" and len(f) >= 4:
                rows.append([run_id, rank, inv, "phase", "", "", f[1], f[3]])
                rows.append([run_id, rank, inv, "phase", "", "", f[1] + ".start_s", f[2]])
            elif f[0] == "ak2-engine" and len(f) >= 3:
                kind, rest = "engine." + f[1], f[2:]
                if f[1] == "shard":
                    rows.append([run_id, rank, inv, kind, "", "", "index", rest[0]])
                    rest = rest[1:]
                for k, v in pairs(rest):
                    rows.append([run_id, rank, inv, kind, "", "", k, v])
            elif f[0] == "ak2-sample":
                kv = dict(pairs(f[1:]))
                for k, v in pairs(f[1:]):
                    if k in ("batch", "name"):
                        continue
                    rows.append([run_id, rank, inv, "sample", kv.get("batch", ""), kv.get("name", ""), k, v])
    return rows


def write(path, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)


def num(v):
    try:
        return float(v)
    except ValueError:
        return None


def rates(rows):
    by = {}
    for r in rows:
        by.setdefault(r[2], []).append(r)
    out = []
    for inv, rs in sorted(by.items()):
        get = lambda kind, metric: [num(r[7]) for r in rs if r[3] == kind and r[6] == metric and num(r[7]) is not None]
        ranks = sorted({r[1] for r in rs})
        load_s, load_b = get("engine.load", "seconds"), get("engine.load", "bytes")
        gbps = [b / s / 1e9 for b, s in zip(load_b, load_s) if s]
        cpu = sum(get("engine.worker", "scan_s")) + sum(get("engine.worker", "lookup_s")) + sum(get("engine.worker", "classify_s"))
        # Pairs: the cohort's sample lines, or a single invocation's ak2-engine result line.
        seqs = sum(get("sample", "sequences")) or sum(get("engine.result", "sequences")) or None
        keys = sum(get("engine.route", "keys"))
        n = len(ranks)
        remote = keys * (n - 1) / n if n else 0
        reads = sum(get("engine.node", "read_s"))
        cut = max(get("engine.node", "blocks_cut") or [0])
        out.append([inv, n, int(seqs) if seqs else "",
                    f"{sum(gbps) / len(gbps):.3f}" if gbps else "", f"{min(gbps):.3f}" if gbps else "",
                    f"{cpu:.3f}",
                    f"{cpu / seqs * 1e6:.3f}" if seqs else "", f"{seqs / cpu:.0f}" if seqs and cpu else "",
                    f"{keys / seqs:.2f}" if seqs else "", f"{remote * 12 / seqs / n:.1f}" if seqs and n else "",
                    f"{reads:.3f}", int(cut),
                    f"{sum(get('engine.node', 'emit_s')):.3f}", f"{sum(get('phase', 'close')):.3f}"])
    return out


RATES_HEAD = ["invocation", "nodes", "pairs", "load_GBps_per_node_mean", "load_GBps_per_node_min",
              "worker_cpu_s", "worker_cpu_us_per_pair", "pairs_per_worker_cpu_s", "lookups_per_pair",
              "routed_lookup_bytes_per_pair_per_node", "read_s_sum", "blocks_cut_max", "emit_s_sum", "close_s_sum"]


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("member", "cohort"):
        sys.exit(__doc__)
    if sys.argv[1] == "member":
        d = sys.argv[2]
        rows = member_rows(d)
        write(os.path.join(d, "tables", "tidy.tsv"), HEAD, rows)
        print(f"tidy: {len(rows)} rows -> {d}/tables/tidy.tsv")
        return
    cdir = sys.argv[2]
    cj = json.load(open(os.path.join(cdir, "cohort.json")))
    gate_dir = os.path.dirname(os.path.normpath(cdir))
    rows = []
    for m in cj.get("members", []):
        if m.get("run_id"):
            rows += member_rows(os.path.join(gate_dir, m["run_id"]))
    write(os.path.join(cdir, "tables", "tidy.tsv"), HEAD, rows)
    rt = rates(rows)
    write(os.path.join(cdir, "tables", "rates.tsv"), RATES_HEAD, rt)
    print(f"tidy: {len(rows)} rows, {len(rt)} invocations -> {cdir}/tables/")


if __name__ == "__main__":
    main()
