#!/usr/bin/env python3
"""One point record of the input-path sweep, schema "inputpath-point/1" (docs/inputpath.md,
"Records and report"; #90).

Usage: record.py --params FILE [--result FILE] [--skip REASON] [--thp MODE] [--pidstat-csv REL]
                 [--output-sha256 H] [--report-sha256 H] [--reference FILE] [--dir DIR]
       record.py --self-test

--params: the body's point parameters (JSON: id, rep, warmup, family, engine, instance_type, db,
db_dir, role pe|se, accession, arm, threads, p, chunk_kib, pipe_requested, thp_requested, decomp,
fq_bytes, nproc, mates [{mate, s3_key, sha256, fastq_sha256, index_s3_key, index_sha256}],
identity [{mate, gz_sha256, rg_sha256, rg_exit, ok, status}], rapidgzip {version, build, isal},
cmd). --result: run_point.py's JSON. --reference: the sample's warm-up I0 record
({output_sha256, report_sha256, sequences}). --skip: the point did not run (the reason).
Prints the record (one line). Status:
  skipped  never used: did not run (--skip: deadline, identity, no best p, no reference), timed
           out (censored), a decoder exited non-zero (decode-crash), or the warm-up (the
           harness's Law 1 reference, run first after drop_caches)
  defect   the classifier failed, or --output / --report / the sequence count differ from the
           warm-up I0's (Law 1), or the warm-up's differ from params.g1_reference, upstream at the
           pin (law1-g1-mismatch: the body then stops the run)
  ok      otherwise
harness.status_detail carries the finer status; note says why for every non-ok record.
"""
import argparse
import json
import os
import sys

SCHEMA = "inputpath-point/1"
RG_ARMS = ("I2", "I3", "I4")


def build(par, res, skip, thp, pidstat_csv, sho, shr, ref, d):
    arm, rg = par["arm"], par["arm"] in RG_ARMS
    rec = {
        "schema": SCHEMA, "point_id": par["id"], "rep": par["rep"], "arm": arm, "engine": par["engine"],
        "family": par["family"], "instance_type": par["instance_type"], "db": par["db"],
        "threads": par["threads"], "thp": thp or par["thp_requested"], "fastq_bytes": par["fq_bytes"],
        "input": {"role": "paired" if par["role"] == "pe" else "single", "accession": par["accession"],
                  "mates": [{k: m[k] for k in ("mate", "s3_key", "sha256", "fastq_sha256") if k in m}
                            for m in par["mates"]]},
    }
    if rg:
        rec["p"] = par["p"]
        rec["rapidgzip"] = par.get("rapidgzip")
        if arm in ("I2", "I4") and par.get("chunk_kib"):
            rec["chunk_mib"] = par["chunk_kib"] // 1024
        if arm == "I3":
            rec["index_sha256"] = " ".join(m.get("index_sha256", "") for m in par["mates"])
            for m, im in zip(rec["input"]["mates"], par["mates"]):
                m["index_s3_key"], m["index_sha256"] = im.get("index_s3_key"), im.get("index_sha256")
        if arm == "I4":
            rec["bgzf_sha256"] = " ".join(m["sha256"] for m in par["mates"])
        ids = par.get("identity") or []
        if ids:
            rec["identity"] = {"gz_sha256": " ".join(i["gz_sha256"] for i in ids),
                               "rg_sha256": " ".join(i["rg_sha256"] for i in ids),
                               "rg_exit": max((i["rg_exit"] if isinstance(i["rg_exit"], int) else 255) for i in ids),
                               "ok": all(i["ok"] for i in ids), "mates": ids}
    if par["engine"] == "ours":
        rec["fanout"] = par["threads"]
    harness = {k: par.get(k) for k in ("warmup", "db_dir", "pipe_requested", "thp_requested", "decomp", "nproc", "cmd", "g1_reference")}
    dt = (par["p"] or 0) * len(par["mates"]) if rg else 0
    harness.update({"decoder_threads": dt, "total_threads": par["threads"] + dt,
                    "oversubscribed": par["threads"] + dt > par["nproc"]})
    rec["harness"] = harness
    if skip:
        rec["status"], rec["note"] = "skipped", skip
        harness["status_detail"] = "skipped-" + skip.split(":")[0].split()[0]
        return rec
    res = res or {}
    g1 = par.get("g1_reference")
    times = res.get("time") or {}
    pipes = []
    for m in par["mates"]:
        f = os.path.join(d or "", f"pipe{m['mate']}.txt")
        try:
            kv = dict(x.split("=", 1) for x in open(f).read().split())
            pipes.append(int(kv["actual"]))
        except (OSError, KeyError, ValueError):
            pass
    if rg and pipes:
        rec["pipe_bytes"] = min(pipes)
        harness["pipe_bytes_per_mate"] = pipes
    rec["wall_s"] = res.get("wall_s")
    rec["classify_reads_per_s"] = res.get("reads_per_s")
    rec["fastq_mb_per_s"] = res.get("fq_mb_per_s_classify")
    if res.get("t_done_s") is not None and res.get("t_stats_s") is not None:
        rec["classify_window"] = {"t0": res["t_done_s"], "t1": res["t_stats_s"]}
    if pidstat_csv and res.get("pidstat"):
        rec["pidstat_csv"] = pidstat_csv
    rss = {}
    if "k2" in times and times["k2"].get("maxrss_kb") is not None:
        rss["kraken2"] = times["k2"]["maxrss_kb"]
    rgr = {k: v.get("maxrss_kb") for k, v in times.items() if k.startswith("rg") and v.get("maxrss_kb") is not None}
    if rgr:
        rss["rapidgzip"] = max(rgr.values())
        for k, v in sorted(rgr.items()):
            rss[f"rapidgzip_mate{k[2:]}"] = v
    for pid, pr in (res.get("procs") or {}).items():
        if pr.get("comm") == "gzip" and pr.get("hwm_kb"):
            rss["gzip"] = max(rss.get("gzip", 0), pr["hwm_kb"])
    if rss:
        rec["peak_rss_kb"] = rss
    rec["output_sha256"], rec["report_sha256"] = sho or None, shr or None
    harness.update({k: res.get(k) for k in ("exit", "timed_out", "load_s", "classify_s", "tail_s", "sequences", "mbp",
                                            "classified", "seq_per_s", "fq_mb_per_s_wall", "smaps_max", "procs",
                                            "procs_left_after_15s", "time", "stderr_tail", "runner_error")})
    harness["pidstat_summary"] = res.get("pidstat")
    harness["reference"] = ref
    dex = {k: v.get("exit", "missing") for k, v in times.items() if k.startswith("rg")}
    if rg and len(dex) < len(par["mates"]):
        dex.update({f"rg{m['mate']}": "missing" for m in par["mates"] if f"rg{m['mate']}" not in dex})
    seqs = res.get("sequences")
    if res.get("timed_out"):
        st, det, note = "skipped", "timeout", f"timed out (censored): killed after the point timeout, wall {res.get('wall_s')} s"
    elif rg and any(v != 0 for v in dex.values()):
        st, det, note = "skipped", "decode-crash", "a decoder exited non-zero: " + ", ".join(f"{k} {v}" for k, v in sorted(dex.items()))
    elif res.get("exit") != 0 or not sho or not shr or seqs is None:
        st, det = "defect", "classifier-failed"
        note = f"the classifier failed: exit {res.get('exit')}, output {'present' if sho else 'missing'}, report {'present' if shr else 'missing'}"
    elif par.get("warmup") and g1 and (sho != g1.get("output_sha256") or shr != g1.get("report_sha256")):
        st, det = "defect", "law1-g1-mismatch"
        note = (f"Law 1 against upstream at the pin: the warm-up I0's output {str(sho)[:12]} / report {str(shr)[:12]} vs the reference "
                f"{str(g1.get('output_sha256'))[:12]} / {str(g1.get('report_sha256'))[:12]} ({g1.get('file')}, sha256 {str(g1.get('sha256'))[:12]})")
    elif par.get("warmup"):
        st, det = "skipped", "reference"
        note = "warm-up: the harness's Law 1 reference for this sample (first run after drop_caches)" + \
            (f"; equal to upstream at the pin ({g1.get('file')})" if g1 else "")
    elif ref and sho == ref.get("output_sha256") and shr == ref.get("report_sha256") and seqs == ref.get("sequences"):
        st, det, note = "ok", "ok", None
    else:
        st, det = "defect", "law1-mismatch"
        note = (f"Law 1: output {str(sho)[:12]} vs {str((ref or {}).get('output_sha256'))[:12]}, report {str(shr)[:12]} vs "
                f"{str((ref or {}).get('report_sha256'))[:12]}, sequences {seqs} vs {(ref or {}).get('sequences')} (the warm-up I0)")
    rec["status"], harness["status_detail"] = st, det
    if note:
        rec["note"] = note
    return rec


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser()
    for k in ("params", "result", "skip", "thp", "pidstat-csv", "output-sha256", "report-sha256", "reference", "dir"):
        ap.add_argument("--" + k, default=None)
    a = ap.parse_args(argv)
    par = json.load(open(a.params))
    res = None
    if a.result:
        try:
            res = json.load(open(a.result))
        except (OSError, ValueError) as e:
            res = {"runner_error": f"{a.result}: {e}"}
    ref = None
    if a.reference and os.path.isfile(a.reference):
        ref = json.load(open(a.reference))
    print(json.dumps(build(par, res, a.skip, a.thp, a.pidstat_csv, a.output_sha256, a.report_sha256, ref, a.dir),
                     separators=(",", ":")))
    return 0


def self_test():
    h = lambda c: c * 64
    par = {"id": "r1-pe-I2-t48-p8", "rep": 1, "warmup": False, "family": "c8g", "engine": "upstream",
           "instance_type": "c8g.16xlarge", "db": "k2_standard_08_GB_20260626", "db_dir": "/mnt/ip-db-huge",
           "role": "pe", "accession": "SRR1", "arm": "I2", "threads": 48, "p": 8, "chunk_kib": 4096,
           "pipe_requested": "1048576", "thp_requested": "always", "decomp": "rapidgzip", "fq_bytes": 100, "nproc": 64,
           "mates": [{"mate": 1, "s3_key": "k1", "sha256": h("a"), "fastq_sha256": h("1")},
                     {"mate": 2, "s3_key": "k2", "sha256": h("b"), "fastq_sha256": h("2")}],
           "identity": [{"mate": 1, "gz_sha256": h("1"), "rg_sha256": h("1"), "rg_exit": 0, "ok": True, "status": "ok"},
                        {"mate": 2, "gz_sha256": h("2"), "rg_sha256": h("2"), "rg_exit": 0, "ok": True, "status": "ok"}],
           "rapidgzip": {"version": "0.14.5", "build": "pypi", "isal": True}, "cmd": "x"}
    ok_res = {"exit": 0, "timed_out": False, "wall_s": 3.0, "sequences": 10, "reads_per_s": 20.0, "fq_mb_per_s_classify": 5.0,
              "t_done_s": 0.5, "t_stats_s": 2.5, "pidstat": {"groups": {}},
              "time": {"k2": {"exit": 0, "maxrss_kb": 9}, "rg1": {"exit": 0, "maxrss_kb": 3}, "rg2": {"exit": 0, "maxrss_kb": 4}}}
    ref = {"output_sha256": h("o"), "report_sha256": h("r"), "sequences": 10}
    cases = [
        ("ok", dict(res=ok_res, sho=h("o"), shr=h("r")), "ok", "ok"),
        ("law1", dict(res=ok_res, sho=h("x"), shr=h("r")), "defect", "law1-mismatch"),
        ("seqcount", dict(res=dict(ok_res, sequences=9), sho=h("o"), shr=h("r")), "defect", "law1-mismatch"),
        ("crash", dict(res=dict(ok_res, time=dict(ok_res["time"], rg2={"exit": 139, "signal": 11})), sho=h("x"), shr=h("r")),
         "skipped", "decode-crash"),
        ("rg-missing", dict(res=dict(ok_res, time={"k2": {"exit": 0}, "rg1": {"exit": 0}}), sho=h("o"), shr=h("r")), "skipped", "decode-crash"),
        ("timeout", dict(res=dict(ok_res, timed_out=True), sho=h("o"), shr=h("r")), "skipped", "timeout"),
        ("failed", dict(res=dict(ok_res, exit=1), sho="", shr=""), "defect", "classifier-failed"),
        ("skip", dict(res=None, skip="identity: crash", sho="", shr=""), "skipped", "skipped-identity"),
    ]
    good = True
    for name, kw, want, det in cases:
        r = build(par, kw["res"], kw.get("skip"), "always", "out/pidstat/x.csv", kw["sho"], kw["shr"], ref, None)
        passed = r["status"] == want and r["harness"]["status_detail"] == det and r["schema"] == SCHEMA
        if name == "ok":
            passed &= (r["identity"]["gz_sha256"] == r["identity"]["rg_sha256"] and r["identity"]["rg_exit"] == 0
                       and r["chunk_mib"] == 4 and r["peak_rss_kb"]["rapidgzip"] == 4 and r["classify_window"] == {"t0": 0.5, "t1": 2.5}
                       and r["input"]["role"] == "paired" and "note" not in r)
        print(f"{'ok  ' if passed else 'FAIL'} record {name}: {r['status']} {r['harness']['status_detail']}")
        good &= passed
    # The warm-up against upstream at the pin (g1_reference): equal -> reference; different -> defect.
    i0 = dict(par, arm="I0", p=None, identity=[], warmup=True, id="warmup-pe",
              g1_reference={"file": "m.json", "sha256": h("f"), "output_sha256": h("o"), "report_sha256": h("r")})
    i0res = dict(ok_res, time={"k2": {"exit": 0, "maxrss_kb": 9}})
    for name, sho, want, det in (("g1-equal", h("o"), "skipped", "reference"), ("g1-differs", h("x"), "defect", "law1-g1-mismatch")):
        r = build(i0, i0res, None, "always", None, sho, h("r"), None, None)
        passed = r["status"] == want and r["harness"]["status_detail"] == det and r["harness"]["g1_reference"]["file"] == "m.json"
        print(f"{'ok  ' if passed else 'FAIL'} record {name}: {r['status']} {r['harness']['status_detail']}")
        good &= passed
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
