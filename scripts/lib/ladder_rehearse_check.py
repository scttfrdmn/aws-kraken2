#!/usr/bin/env python3
"""The checks of make rehearse-ladder (scripts/lib/ladder_rehearse.sh; docs/ladder.md, "The
rehearsal"), on one rehearsal cohort's observed output: what each node streamed (its container's
stdout), what it pushed to the stand-in bucket (log/run.log, out/*), and the objects it uploaded.
Every check is a line "ok   <case>: <id>: <what>" or "FAIL <case>: <id>: <what>".

  ladder_rehearse_check.py check CASE.json [--expect-fail ID[,ID...]]
      exit 0 if every check passed; with --expect-fail (a negative control), exit 0 only if each
      named check FAILED (the probe resolves the defect the mutation planted) and print which.
  ladder_rehearse_check.py record CASE.json RECORD_DIR SPEC
      the cohort as a run record (RECORD_DIR/results/g3/<cohort>/cohort.json and each member's
      manifest.json, log/ and out/), for scripts/lib/ladder_tables.py. Rehearsal records only:
      instance times are the containers' start and end, cost_usd is null (not an AWS run).

CASE.json (written by ladder_rehearse.sh): name, rung, cid, bucket (the stand-in results root
.../aws-kraken2/g3), nodes [{rank, out, rc, start, end}], samples, refdir, refmap {sample: ref},
params {KEY: value}, expect {...}.
"""
import collections, hashlib, json, os, re, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


class Checks:
    def __init__(self, case):
        self.case, self.res = case, collections.OrderedDict()

    def need(self, cid, cond, what):
        ok = bool(cond)
        print(f"{'ok  ' if ok else 'FAIL'} {self.case}: {cid}: {what}")
        self.res.setdefault(cid, True)
        if not ok:
            self.res[cid] = False
        return ok


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def lines(p):
    try:
        with open(p, errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def tagged(ls, tag):
    pre = tag + " "
    return [l[len(pre):] for l in ls if l.startswith(pre)]


def jl(ss):
    out = []
    for s in ss:
        try:
            out.append(json.loads(s))
        except ValueError:
            out.append(None)
    return out


def phases_of(ls):
    """[(name, epoch, cold)] from the ak2-phase lines, and run.sh's phases.tsv rows."""
    ph = []
    for l in ls:
        p = l.split("\t")
        if p[0] == "ak2-phase" and len(p) >= 4:
            ph.append((p[3], int(p[2]), (p[4] if len(p) > 4 and p[4] else "no")))
    return ph


def phases_tsv(ls):
    """run.sh's derivation (tables/phases.tsv): seconds to the next phase marker."""
    ph = phases_of(ls)
    rows = []
    for i, (n, ep, cold) in enumerate(ph):
        if n == "end":
            continue
        sec = ph[i + 1][1] - ep if i + 1 < len(ph) else None
        rows.append({"phase": n, "epoch": ep, "seconds": sec, "cold": cold})
    return rows


def expected_phases(p):
    eng = p["CLASSIFIER"] == "ours-engine"
    seq = ["preamble", "body", "setup", "fetch-db"]
    if not eng:
        seq.append("etag-hash.k2d")
    seq.append("fetch-inputs")
    if p["SETUP"] == "overlap":
        seq.append("build-wait")
    if p["GUNZIP"] != "gzip":
        seq.append("identity")
    seq.append("load")
    if eng:
        seq.append("etag-hash.k2d")
    seq += ["classify", "upload-drain"]
    if p["OUT_UPLOAD"] == "sdk-stream":
        seq.append("sha-get")
    seq += ["push", "end"]
    return seq


def node_files(c, n):
    d = os.path.join(c["bucket"], f"{c['cid']}-r{n['rank']}")
    return d, os.path.join(d, "log", "run.log"), os.path.join(d, "out")


def read_tsv(p):
    ls = lines(p)
    if not ls:
        return []
    h = ls[0].split("\t")
    return [dict(zip(h, l.split("\t"))) for l in ls[1:] if l.strip()]


def check(c, expect_fail):
    K = Checks(c["name"])
    p, ex = c["params"], c.get("expect", {})
    want_ok = ex.get("exit", "ok") == "ok"
    rung, nodes, samples = c["rung"], c["nodes"], c["samples"]
    eng, sdk = p["CLASSIFIER"] == "ours-engine", p["OUT_UPLOAD"] == "sdk-stream"
    rcs = [n["rc"] for n in nodes]
    if want_ok:
        K.need("exit", all(r == 0 for r in rcs), f"every node's body exits 0 (rcs {rcs})")
    else:
        K.need("exit", any(r != 0 for r in rcs), f"the run fails (rcs {rcs})")
    logs, outs = {}, {}
    for n in nodes:
        d, lp, od = node_files(c, n)
        logs[n["rank"]], outs[n["rank"]] = lines(lp), od
        K.need("preamble", any(re.search(r"inherited \$-=\S*e", l) for l in logs[n["rank"]]),
               f"r{n['rank']}: the payload ran under bash -e -c and the preamble's set +e (pushed log/run.log)")
    for m in ex.get("messages", []):
        hit = [n["rank"] for n in nodes if any(m in l for l in logs[n["rank"]] + lines(n["out"]))]
        K.need("message", hit, f"{m!r} in the log of rank(s) {hit}")
    if ex.get("pipefail_off"):
        K.need("pipefail", all(any(l.endswith("rehearsal: pipefail off") for l in logs[n["rank"]]) for n in nodes),
               "the body ran with pipefail off (as on the node: bash -e -c, then the preamble's set +e)")
    if not want_ok:
        return finish(K, expect_fail)

    # ---- streaming: what each node streamed equals what it pushed ----
    per_node = {}
    for n in nodes:
        r = n["rank"]
        ls, od = logs[r], outs[r]
        st = tagged(ls, "lad-sample")
        pu = lines(os.path.join(od, "lad-samples.jsonl"))
        K.need("stream", st == pu and (st or (eng and p["SHARDS"] != "1")),
               f"r{r}: {len(st)} lad-sample lines streamed into run.log, equal to the pushed out/lad-samples.jsonl ({len(pu)})")
        cap = tagged(lines(n["out"]), "lad-sample")
        K.need("stream", cap == st, f"r{r}: the container's own stdout (the stream as it happened) has the same {len(cap)} lad-sample lines")
        sn, pn = tagged(ls, "lad-net"), lines(os.path.join(od, "lad-net.jsonl"))
        K.need("stream", len(sn) == 1 and sn == pn, f"r{r}: one lad-net line streamed and the same one pushed ({len(sn)}, {len(pn)})")
        lv = collections.Counter(tagged(ls, "lever"))
        lp = collections.Counter(lines(os.path.join(od, "lever.jsonl")))
        K.need("stream", lv == lp and sum(lv.values()) > 0, f"r{r}: lever lines streamed ({sum(lv.values())}) equal the pushed lever.jsonl ({sum(lp.values())})")
        per_node[r] = {"samples": [x for x in jl(pu) if x], "net": (jl(pn) or [None])[0],
                       "lad": [x for x in jl(lines(os.path.join(od, "lad.jsonl"))) if x]}

    # ---- the cohort: every planned sample once, rc 0 ----
    allsam = [s for r in per_node for s in per_node[r]["samples"]]
    acc = collections.Counter(s.get("accession") for s in allsam)
    K.need("samples", sorted(acc) == sorted(samples) and all(v == 1 for v in acc.values()),
           f"each planned sample has exactly one lad-sample line across the fleet ({dict(acc)}; planned {samples})")
    K.need("samples", all(s.get("rc") == 0 for s in allsam), f"every sample's classify rc is 0 ({[s.get('rc') for s in allsam]})")
    K.need("samples", all(s.get("v") == 1 and s.get("rung") == rung and s.get("arm") == p["ARM"] for s in allsam),
           "every lad-sample is contract v1 with the run's rung and arm")

    # ---- Law 1: each output and report equals upstream at the pin (the oracle), and the uploaded object ----
    od_c = os.path.join(c["bucket"], c["cid"], "out", rung)
    for s in allsam:
        a = s.get("accession")
        ref = c["refmap"].get(a, a)
        for role in ("output", "report"):
            want = open(os.path.join(c["refdir"], f"{ref}.{role}.sha256")).read().split()[0]
            got = ((s.get("outputs") or {}).get(role) or {}).get("sha256")
            K.need("law1", got == want, f"{a} {role}: on-node sha256 {str(got)[:16]} == oracle {want[:16]} (upstream at the pin, {ref})")
            obj = os.path.join(od_c, a, role)
            osha = sha_file(obj) if os.path.exists(obj) else None
            K.need("objects", osha == got, f"{a} {role}: the uploaded object's sha256 {str(osha)[:16]} == the recorded {str(got)[:16]}")
        K.need("law1", set((s.get("outputs") or {})) == {"output", "report"}, f"{a}: the file set is output and report")
    nobj = sum(len(fs) for _, _, fs in os.walk(od_c)) if os.path.isdir(od_c) else 0
    K.need("objects", nobj == 2 * len(samples), f"{nobj} objects under out/{rung}/ (want {2 * len(samples)})")
    if sdk:
        K.need("sdk", all(str(s.get("sha256_source", "")).startswith("s3 GET") for s in allsam),
               "every sha256 came from a GET of the object the SDK emitter wrote (sha256_source)")

    # ---- phases: every phase, in order; exactly the two drop_caches mark cold phases ----
    want_seq = expected_phases(p)
    for n in nodes:
        r = n["rank"]
        ph = phases_of(logs[r])
        names = [x[0] for x in ph]
        K.need("phases", names == want_seq, f"r{r}: phases {names}" + ("" if names == want_seq else f" (want {want_seq})"))
        cold = [x[0] for x in ph if x[2] == "yes"]
        K.need("phases", cold == ["setup", "load"], f"r{r}: phases.tsv cold markers {cold} (want setup and load: the body's two drop_caches)")
        ndc = sum(1 for l in logs[r] if "drop_caches done; next phase is cold" in l)
        K.need("phases", ndc == 2, f"r{r}: {ndc} drop_caches calls in the log (want 2)")

    # ---- lad-net: components equal the phase and sample sums ----
    for n in nodes:
        r = n["rank"]
        net, ss = per_node[r]["net"], per_node[r]["samples"]
        if not isinstance(net, dict):
            K.need("net", False, f"r{r}: no lad-net line")
            continue
        tsv = {x["phase"]: x for x in phases_tsv(logs[r])}
        sc = round(sum((s.get("phases") or {}).get("sha-critical") or 0 for s in ss), 3)
        parts = (net.get("identity_s"), net.get("sha_get_s"), net.get("sha_critical_s"))
        K.need("net", net.get("v") == 1 and net.get("rank") == r and None not in parts and
               abs(sum(parts) - net.get("critical_measurement_s", -1)) <= 0.001,
               f"r{r}: critical_measurement_s {net.get('critical_measurement_s')} = identity {parts[0]} + sha_get {parts[1]} + sha_critical {parts[2]}")
        K.need("net", abs((net.get("sha_critical_s") or 0) - sc) <= 0.001 * max(1, len(ss)),
               f"r{r}: sha_critical_s {net.get('sha_critical_s')} == the sum of its samples' sha-critical {sc}")
        for comp, ph in (("identity_s", "identity"), ("sha_get_s", "sha-get")):
            v = net.get(comp) or 0
            if ph in tsv and tsv[ph]["seconds"] is not None:
                K.need("net", abs(v - tsv[ph]["seconds"]) <= 1.5 and (v > 0 or tsv[ph]["seconds"] == 0),
                       f"r{r}: {comp} {v} equals the {ph} phase ({tsv[ph]['seconds']} s, whole-second markers)")
            else:
                K.need("net", v == 0, f"r{r}: {comp} {v} is 0 (no {ph} phase)")
        if "identity" in tsv:
            sid = round(sum((s.get("phases") or {}).get("s5-identity") or 0 for s in ss), 3)
            K.need("net", sid > 0, f"r{r}: the samples carry their share of identity (s5-identity sum {sid})")

    # ---- requests ----
    tot_up, tot_head = 0, 0
    for n in nodes:
        r = n["rank"]
        rq = read_tsv(os.path.join(outs[r], "requests.tsv"))
        cnt = collections.Counter()
        for x in rq:
            try:
                cnt[(x.get("phase"), x.get("op"))] += int(x.get("count") or 0)
            except ValueError:
                pass
        ops = collections.Counter()
        for (ph, op), v in cnt.items():
            ops[op] += v
        up = sum(v for op, v in ops.items() if re.fullmatch(r"(PutObject|CompleteMultipartUpload)(-estimate)?", op)) - ops["Rendezvous-PutObject"]
        tot_up += up
        tot_head += sum(v for (ph, op), v in cnt.items() if ph == "fetch-inputs" and op == "HeadObject")
        if eng:
            K.need("requests", ops["GetObject-range"] > 0, f"r{r}: the shard load's ranged GETs counted (GetObject-range {ops['GetObject-range']})")
        else:
            st = sum(v for (ph, op), v in cnt.items() if ph == "fetch-db" and op.startswith("GetObject"))
            K.need("requests", st >= 3, f"r{r}: the database staging counted ({st} GetObject requests in fetch-db)")
    K.need("requests", tot_up == 2 * len(samples), f"output uploads counted: PutObject + CompleteMultipartUpload - Rendezvous-PutObject = {tot_up} (want {2 * len(samples)}, the objects)")
    K.need("requests", tot_head == 2 * len(samples), f"input fetches counted: fetch.sh's HeadObject = {tot_head} (want {2 * len(samples)}, one per input file)")

    # ---- engine: the ETag check ran on the loaded table ----
    if eng:
        for n in nodes:
            r = n["rank"]
            el = [l.split("\t") for l in lines(os.path.join(outs[r], f"eng-rank{r}.stderr")) if l.startswith("ak2-engine\tetag\t")]
            K.need("engine", el and el[-1][3] == el[-1][5], f"r{r}: ak2-engine etag line: etag {el[-1][3] if el else '-'} computed {el[-1][5] if el else '-'}")
        homes = collections.Counter(s.get("rank") for s in allsam)
        if int(p["SHARDS"]) > 1:
            K.need("engine", len(homes) == int(p["SHARDS"]), f"every shard homed samples ({dict(homes)}): the placement spread them")
        rv = os.path.join(c["bucket"], c["cid"], "rendezvous")
        for g in range(int(p["REPLICAS"])):
            recs = sorted(f for f in os.listdir(os.path.join(rv, f"g{g}")) if f.startswith("rank-")) if os.path.isdir(os.path.join(rv, f"g{g}")) else []
            K.need("engine", len(recs) == int(p["SHARDS"]), f"replica {g} has its own rendezvous (g{g}: {recs})")
            for f in recs:
                addr = (json.load(open(os.path.join(rv, f"g{g}", f))).get("shard_addr") or "")
                K.need("engine", addr.split(":")[0] != "127.0.0.1" and addr.split(":")[0] != "", f"replica {g} {f}: shard address {addr} is the node's own, not loopback")

    # ---- the upload schedule: serial blocks the lane, overlap does not; lanes run at once ----
    for n in nodes:
        r = n["rank"]
        ss = sorted(per_node[r]["samples"], key=lambda s: s["t_start"])
        ups = read_tsv(os.path.join(outs[r], "lever-uploads.tsv"))
        upend = collections.defaultdict(float)
        for u in ups:
            m = re.search(r"/out/([^/]+)/(output|report)$", u.get("local", ""))
            if m:
                upend[m.group(1)] = max(upend[m.group(1)], float(u["t_end"]))
        bylane = collections.defaultdict(list)
        for s in ss:
            bylane[s.get("lane")].append(s)
        pairs = [(a, b) for L in bylane.values() for a, b in zip(L, L[1:])]
        if ex.get("order") == "serial":
            K.need("order", pairs and all(b["t_start"] >= upend[a["accession"]] - 0.005 for a, b in pairs),
                   f"r{r}: serial: each lane's next sample starts after the previous one's uploads end "
                   f"({[(a['accession'], round(b['t_start'] - upend[a['accession']], 3)) for a, b in pairs]})")
        if ex.get("order") == "overlap":
            K.need("order", pairs and any(b["t_start"] < upend[a["accession"]] for a, b in pairs),
                   f"r{r}: overlap: a lane's next sample starts before the previous one's uploads end "
                   f"({[(a['accession'], round(b['t_start'] - upend[a['accession']], 3)) for a, b in pairs]})")
        if ex.get("lanes", 1) > 1:
            lanes = {s.get("lane") for s in ss}
            ov = any(a["t_start"] < b["t_end"] and b["t_start"] < a["t_end"] for a in ss for b in ss if a.get("lane") != b.get("lane"))
            K.need("order", len(lanes) == ex["lanes"] and ov, f"r{r}: {len(lanes)} lanes (want {ex['lanes']}), whose classify spans overlap: {ov}")

    # ---- build: SETUP's wait, and the overlap order ----
    for n in nodes:
        r = n["rank"]
        b = [x for x in per_node[r]["lad"] if x.get("kind") == "build"]
        ph = {x[0]: x[1] for x in phases_of(logs[r])}
        if not b:
            K.need("build", False, f"r{r}: no lad-build line")
            continue
        b = b[-1]
        if p["SETUP"] == "overlap":
            nxt = ph.get("identity", ph.get("load"))
            K.need("build", b.get("waited_in_phase") == "build-wait" and b.get("build_end") is not None
                   and nxt is not None and b["build_end"] <= nxt + 1,
                   f"r{r}: overlap: waited in build-wait, build_end {b.get('build_end')} recorded, before {'identity' if 'identity' in ph else 'load'} ({nxt})")
            if ex.get("slow_build"):
                K.need("build", b.get("wait_s", 0) > 1, f"r{r}: the build was still running at build-wait (wait_s {b.get('wait_s')}): the overlap is observed")
        else:
            K.need("build", b.get("waited_in_phase") == "setup", f"r{r}: serial: the build waited for in setup ({b.get('waited_in_phase')})")

    # ---- S5: identity, fallback, call counts ----
    if p["GUNZIP"] != "gzip":
        s5 = ex.get("s5", {})
        differs = set(s5.get("differs", []))
        defect = set(s5.get("defect", []))
        for n in nodes:
            r = n["rank"]
            ss = per_node[r]["samples"]
            cfg = [x for x in per_node[r]["lad"] if x.get("kind") == "config"]
            P = (cfg[-1].get("resolved") or {}).get("gunzip_P") if cfg else None
            ids = [x for x in per_node[r]["lad"] if x.get("kind") == "identity"]
            mine = sorted(s.get("accession") for s in ss)
            K.need("s5", sorted(x["file"] for x in ids) == sorted(f"{a}_{m}.fastq.gz" for a in mine for m in (1, 2)),
                   f"r{r}: one identity line per input file this node read ({len(ids)})")
            K.need("s5", all(x.get("rapidgzip_P") == P for x in ids) and P, f"r{r}: identity at the run's -P {P} (lad-config gunzip_P)")
            got_def = {x["file"] for x in ids if x.get("input_defect")}
            K.need("s5", got_def == {f for f in defect if f.split("_")[0] in mine},
                   f"r{r}: input_defect on {sorted(got_def)} (want {sorted(f for f in defect if f.split('_')[0] in mine)})")
            for s in ss:
                a, v = s["accession"], s.get("s5") or {}
                wd = a in differs
                ok = (v.get("status") == ("differs" if wd else "identical") and v.get("fallback") == ("gzip" if wd else "none")
                      and v.get("P") == P and all(len(v.get(k) or []) == 2 for k in ("gz_sha256", "rg_sha256", "gz_exit", "rg_exit")))
                if ok and not wd:
                    ok = v["gz_sha256"] == v["rg_sha256"] and v["gz_exit"] == [0, 0] and v["rg_exit"] == [0, 0] and EMPTY not in v["gz_sha256"]
                K.need("s5", ok, f"r{r}: {a}: s5 {v.get('status')}/{v.get('fallback')} P {v.get('P')} gz_exit {v.get('gz_exit')} rg_exit {v.get('rg_exit')} "
                       f"(want {'differs/gzip' if wd else 'identical/none'})")
            for x in ids:
                ind = (s5.get("independent") or {}).get(x["file"])
                if ind:
                    K.need("s5", [x.get("gzip_exit"), x.get("rapidgzip_exit"), x.get("rapidgzip_sha256")] == ind,
                           f"r{r}: {x['file']}: recorded gzip exit {x.get('gzip_exit')}, rapidgzip exit {x.get('rapidgzip_exit')} and sha "
                           f"{str(x.get('rapidgzip_sha256'))[:12]} equal an independent run of the same tools ({ind[0]}, {ind[1]}, {str(ind[2])[:12]})")
            nfb = sum(1 for s in ss if s["accession"] in differs)
            calls = lines(os.path.join(outs[r], "gzip-shim.calls"))
            nrg = sum(1 for l in calls if "\trapidgzip\t" in l)
            fb = lines(os.path.join(outs[r], "s5-fallback.calls"))
            nfc = sum(1 for l in fb if "\tgzip-fallback\t" in l)
            K.need("s5", nrg == 2 * (len(ss) - nfb), f"r{r}: gzip-shim.calls has {nrg} rapidgzip calls (want {2 * (len(ss) - nfb)}: two mates of each non-fallback sample)")
            K.need("s5", nfc == 2 * nfb and all(any(f"/{a}_" in l for l in fb) for a in differs if a in mine),
                   f"r{r}: s5-fallback.calls has {nfc} GNU gzip calls (want {2 * nfb}), naming the fallback samples' inputs")
            sh = [x for x in per_node[r]["lad"] if x.get("kind") == "shim"]
            K.need("s5", sh and sh[-1].get("ok") is True, f"r{r}: the body's own shim check (lad-shim ok {sh[-1].get('ok') if sh else None})")

    # ---- the tail: hashes after every classify span, with uploads lagging behind them ----
    if ex.get("tail"):
        for n in nodes:
            r = n["rank"]
            ss, net = per_node[r]["samples"], per_node[r]["net"] or {}
            end = max(s["t_end"] for s in ss)
            lev = [x for x in jl(lines(os.path.join(outs[r], "lever.jsonl"))) if x and x.get("kind") == "upload-enqueue"]
            tail = [(x["t"] - x["sha256_seconds"], x["t"], x["local"]) for x in lev if x["t"] - x["sha256_seconds"] >= end]
            big = [t for t in tail if t[2].endswith("/output")]
            naive = round(sum(t[1] - t[0] for t in tail), 3)
            first = round(min(tail)[1] - min(tail)[0], 3) if tail else 0
            mx = max((t[1] - t[0] for t in tail), default=0)
            crit = net.get("sha_critical_s")
            K.need("tail", len(big) >= 2, f"r{r}: the probe resolves: {len(big)} output hashes ({len(tail)} files) after the last classify span ended (want >= 2)")
            K.need("tail", crit is not None and crit <= 1.2 * mx + 0.01 and naive >= 1.8 * max(crit, 0.001),
                   f"r{r}: sha_critical_s {crit} is about one hash (the first, {first}; the largest {round(mx, 3)}), not the tail's {len(tail)} hashes ({naive})")
    return finish(K, expect_fail)


def finish(K, expect_fail):
    if expect_fail:
        bad = [i for i in expect_fail if K.res.get(i, True)]
        for i in expect_fail:
            print(f"{'ok  ' if not K.res.get(i, True) else 'FAIL'} {K.case}: negative control: check {i} "
                  f"{'FAILED, as the mutation must make it' if not K.res.get(i, True) else 'did not fail: it cannot see the planted defect'}")
        return 1 if bad else 0
    return 0 if all(K.res.values()) else 1


def record(c, recdir, spec):
    """The cohort as run-multi.sh leaves it, for ladder_tables.py (rehearsal: no AWS fields)."""
    params = json.loads(subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "lib", "ladder_levers.py"), "spec-params", spec],
                                       capture_output=True, text=True, check=True).stdout)
    g = os.path.join(recdir, "results", "g3")
    cd = os.path.join(g, c["cid"])
    os.makedirs(cd, exist_ok=True)
    commit = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
    members = []
    for n in c["nodes"]:
        rid = f"{c['cid']}-r{n['rank']}"
        md = os.path.join(g, rid)
        src, lp, od = node_files(c, n)
        os.makedirs(os.path.join(md, "log"), exist_ok=True)
        subprocess.run(["cp", "-R", od, os.path.join(md, "out")], check=True)
        subprocess.run(["cp", lp, os.path.join(md, "log", "run.log")], check=True)
        ph = phases_tsv(lines(lp))
        man = {"rehearsal": "make rehearse (scripts/lib/ladder_rehearse.sh): a local container run, not an AWS run; "
                            "instance times are the container's start and end, and there is no cost",
               "gate": "g3", "run_id": rid, "spec": spec, "params": params, "commit": commit, "region": "us-west-2",
               "instance": {"type": c.get("type"), "az": "rehearsal", "launch_time": n["start"], "terminated_at": n["end"]},
               "truffle_price_usd_per_hour": None, "cost_usd": None,
               "sample_accessions": c["samples"], "sample_accessions_ref": None,
               "cohort": {"id": c["cid"], "rank": n["rank"], "n": len(c["nodes"])},
               "phases": [{"phase": x["phase"], "seconds": x["seconds"], "cold": x["cold"] == "yes"} for x in ph],
               "task": {"exit_code": n["rc"]}}
        with open(os.path.join(md, "manifest.json"), "w") as f:
            json.dump(man, f, indent=2)
        members.append({"rank": n["rank"], "run_id": rid, "rc": str(n["rc"])})
    coh = {"cohort_id": c["cid"], "gate": "g3", "spec": spec, "commit": commit, "params": params, "nodes": len(c["nodes"]),
           "instance_type": c.get("type"), "sample_accessions_ref": None, "members": members, "cost_usd": None,
           "rehearsal": "make rehearse: local containers, not AWS"}
    with open(os.path.join(cd, "cohort.json"), "w") as f:
        json.dump(coh, f, indent=2)
    print(f"record: {cd}")
    return 0


def main(a):
    if len(a) >= 2 and a[0] == "check":
        c = json.load(open(a[1]))
        ef = []
        if len(a) >= 4 and a[2] == "--expect-fail":
            ef = a[3].split(",")
        return check(c, ef)
    if len(a) == 4 and a[0] == "record":
        return record(json.load(open(a[1])), a[2], a[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
