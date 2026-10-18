#!/usr/bin/env python3
"""The input-path sweep's per-point table (docs/inputpath.md, "Where each field lives"; #90).

Usage: tables.py POINTS_JSONL OUT_TSV       (the body, at the end of a run: out/inputpath.tsv)
       tables.py --run RESULTS_RUN_DIR      (the post script: out/points.jsonl ->
                                             tables/inputpath.tsv, and tables/inputpath-defects.tsv)

One row per point record (schema inputpath-point/1): the manifest fields the plan adds for this
sweep (arm, p, threads, chunk, pipe, THP, rapidgzip version/build/ISA-L, input keys and sha256,
index and BGZF sha256, pidstat CSV, peak RSS, output and report sha256) and the measurements
(wall, classify window, reads/s, FASTQ MB/s, per-group CPU from pidstat). Values absent from a
record are "-". Prints a DEFECT line per defect point (exit 0: the defect is a finding, recorded).
"""
import json
import os
import sys

COLS = ["point_id", "rep", "status", "status_detail", "family", "engine", "instance_type", "arm", "role", "accession",
        "threads", "p", "chunk_mib", "pipe_bytes", "thp", "decomp", "wall_s", "load_s", "classify_s",
        "classify_reads_per_s", "fastq_mb_per_s", "fastq_mb_per_s_wall", "fastq_bytes", "sequences",
        "output_sha256", "report_sha256", "identity_ok", "rapidgzip_version", "rapidgzip_build", "rapidgzip_isal",
        "input_s3_keys", "input_sha256", "index_sha256", "bgzf_sha256", "peak_rss_kraken2_kb", "peak_rss_rapidgzip_kb",
        "cpu_engine_main_s", "cpu_engine_workers_s", "cpu_rapidgzip_s", "cpu_gzip_s", "max_engine_thread_mean_cpu_pct",
        "max_rapidgzip_thread_mean_cpu_pct", "anon_huge_kb", "shmem_pmd_kb", "file_pmd_kb", "decoder_threads",
        "total_threads", "oversubscribed", "pidstat_csv", "note"]


def row(p):
    h = p.get("harness") or {}
    g = ((h.get("pidstat_summary") or {}).get("groups")) or {}
    sm = h.get("smaps_max") or {}
    rg = p.get("rapidgzip") or {}
    inp = p.get("input") or {}
    mates = inp.get("mates") or []
    rss = p.get("peak_rss_kb") or {}
    idn = p.get("identity")

    def gm(k, f):
        return (g.get(k) or {}).get(f)

    eng_max = max([x for x in (gm("engine_main", "max_thread_mean_cpu_pct"), gm("engine_workers", "max_thread_mean_cpu_pct"))
                   if x is not None], default=None)
    v = {
        "point_id": p.get("point_id"), "rep": p.get("rep"), "status": p.get("status"), "status_detail": h.get("status_detail"),
        "family": p.get("family"), "engine": p.get("engine"), "instance_type": p.get("instance_type"), "arm": p.get("arm"),
        "role": inp.get("role"), "accession": inp.get("accession"), "threads": p.get("threads"), "p": p.get("p"),
        "chunk_mib": p.get("chunk_mib"), "pipe_bytes": p.get("pipe_bytes"), "thp": p.get("thp"), "decomp": h.get("decomp"),
        "wall_s": p.get("wall_s"), "load_s": h.get("load_s"), "classify_s": h.get("classify_s"),
        "classify_reads_per_s": p.get("classify_reads_per_s"), "fastq_mb_per_s": p.get("fastq_mb_per_s"),
        "fastq_mb_per_s_wall": h.get("fq_mb_per_s_wall"), "fastq_bytes": p.get("fastq_bytes"), "sequences": h.get("sequences"),
        "output_sha256": p.get("output_sha256"), "report_sha256": p.get("report_sha256"),
        "identity_ok": None if idn is None else idn.get("ok"),
        "rapidgzip_version": rg.get("version") if p.get("arm") in ("I2", "I3", "I4") else None,
        "rapidgzip_build": rg.get("build") if p.get("arm") in ("I2", "I3", "I4") else None,
        "rapidgzip_isal": rg.get("isal") if p.get("arm") in ("I2", "I3", "I4") else None,
        "input_s3_keys": " ".join(str(m.get("s3_key")) for m in mates), "input_sha256": " ".join(str(m.get("sha256")) for m in mates),
        "index_sha256": p.get("index_sha256"), "bgzf_sha256": p.get("bgzf_sha256"),
        "peak_rss_kraken2_kb": rss.get("kraken2"), "peak_rss_rapidgzip_kb": rss.get("rapidgzip"),
        "cpu_engine_main_s": gm("engine_main", "cpu_s"), "cpu_engine_workers_s": gm("engine_workers", "cpu_s"),
        "cpu_rapidgzip_s": gm("rapidgzip", "cpu_s"), "cpu_gzip_s": gm("gzip", "cpu_s"),
        "max_engine_thread_mean_cpu_pct": eng_max, "max_rapidgzip_thread_mean_cpu_pct": gm("rapidgzip", "max_thread_mean_cpu_pct"),
        "anon_huge_kb": sm.get("AnonHugePages_kb"), "shmem_pmd_kb": sm.get("ShmemPmdMapped_kb"), "file_pmd_kb": sm.get("FilePmdMapped_kb"),
        "decoder_threads": h.get("decoder_threads"), "total_threads": h.get("total_threads"), "oversubscribed": h.get("oversubscribed"),
        "pidstat_csv": p.get("pidstat_csv"), "note": p.get("note"),
    }
    out = []
    for c in COLS:
        x = v[c]
        out.append("-" if x is None or x == "" else (str(x).lower() if isinstance(x, bool) else str(x).replace("\t", " ")))
    return out


def write(points_path, out_tsv, defects_tsv=None):
    pts = [json.loads(l) for l in open(points_path) if l.strip()]
    with open(out_tsv, "w") as f:
        f.write("\t".join(COLS) + "\n")
        for p in pts:
            f.write("\t".join(row(p)) + "\n")
    bad = [p for p in pts if p.get("status") == "defect"]
    for p in bad:
        print(f"DEFECT {p.get('point_id')}: {p.get('note')}")
    if defects_tsv is not None:
        with open(defects_tsv, "w") as f:
            f.write("point_id\tstatus_detail\tnote\n")
            for p in bad:
                f.write(f"{p.get('point_id')}\t{(p.get('harness') or {}).get('status_detail')}\t{p.get('note')}\n")
    print(f"inputpath tables: {len(pts)} points ({sum(p.get('status') == 'ok' for p in pts)} ok, "
          f"{sum(p.get('status') == 'skipped' for p in pts)} skipped, {len(bad)} defects) -> {out_tsv}")
    return 0


def main(argv):
    if argv[:1] == ["--run"] and len(argv) == 2:
        run = argv[1]
        src = os.path.join(run, "out", "points.jsonl")
        if not os.path.isfile(src):
            print(f"inputpath tables: {src}: no point records", file=sys.stderr)
            return 1
        os.makedirs(os.path.join(run, "tables"), exist_ok=True)
        return write(src, os.path.join(run, "tables", "inputpath.tsv"), os.path.join(run, "tables", "inputpath-defects.tsv"))
    if len(argv) == 2:
        return write(argv[0], argv[1])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
