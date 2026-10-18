#!/usr/bin/env python3
"""scripts/inputpath/inputs.tsv: the input-path sweep's test inputs (docs/inputpath.md, "Inputs"; #90).

Usage:
  inputs.py check FILE [--accessions "ACC ..."]   validate; print the normalised rows (TSV, no
                                                    header: role accession mate bucket key sha256
                                                    kind source_sha256), exit 1 (saying why) if bad
  inputs.py keys FILE                               the s3:// URIs of every row but fastq, one per line
  inputs.py accessions FILE                         the accessions, pe first, space-separated
  inputs.py --self-test

The file is written by the input preparation (#90, part 2). Header (tab-separated, in this order):
role accession mate s3_key sha256 kind source_sha256. Rules:
  role    pe (also: paired) or se (also: single); exactly one accession per role, both roles
  mate    1 or 2 for pe; 1 for se (0, - or empty are read as 1)
  s3_key  a key in the project bucket (aws-kraken2-942542972736-us-west-2), or a full
          s3://<that bucket>/<key>; no other bucket (the cookbook bucket is denied by design)
  sha256  64 hex: the object's own sha256 (the body checks every staged object against it)
  kind    gz (the published .fastq.gz), bgzf (its BGZF re-encode, I4), index (a rapidgzip
          index of the gz, I3, --import-index), fastq (optional: the plain FASTQ; not staged,
          its sha256 must equal gzip -dc of the gz)
  source_sha256  what the object derives from: for gz and fastq, the decompressed FASTQ (or
          empty / -); for bgzf, the FASTQ or the gz; for index, the gz or the FASTQ. The body
          accepts any of these and refuses anything else.
Required: per role and mate, one gz, one bgzf and one index row.
"""
import re
import sys

BUCKET = "aws-kraken2-942542972736-us-west-2"
HEADER = ["role", "accession", "mate", "s3_key", "sha256", "kind", "source_sha256"]
ROLE = {"pe": "pe", "paired": "pe", "se": "se", "single": "se"}
KINDS = ("gz", "bgzf", "index", "fastq")
HEX = re.compile(r"^[0-9a-f]{64}$")


def load(path):
    try:
        lines = [l.rstrip("\n").rstrip("\r") for l in open(path)]
    except OSError as e:
        raise SystemExit(f"inputs: {path}: {e} (the input preparation, #90 part 2, writes it)")
    lines = [l for l in lines if l.strip() and not l.startswith("#")]
    if not lines or lines[0].split("\t") != HEADER:
        raise SystemExit(f"inputs: {path}: the header must be {' '.join(HEADER)} (tab-separated)")
    rows, errs = [], []
    for n, l in enumerate(lines[1:], 2):
        f = l.split("\t")
        if len(f) != len(HEADER):
            errs.append(f"line {n}: {len(f)} fields, want {len(HEADER)}")
            continue
        r = dict(zip(HEADER, (x.strip() for x in f)))
        role = ROLE.get(r["role"].lower())
        if not role:
            errs.append(f"line {n}: role '{r['role']}' is not pe/se")
            continue
        mate = r["mate"] if r["mate"] not in ("", "-", "0") else "1"
        if mate not in ("1", "2") or (role == "se" and mate != "1"):
            errs.append(f"line {n}: mate '{r['mate']}' for role {role}")
        key = r["s3_key"]
        bucket = BUCKET
        if key.startswith("s3://"):
            bucket, _, key = key[5:].partition("/")
        if bucket != BUCKET or not key or key.endswith("/"):
            errs.append(f"line {n}: s3_key '{r['s3_key']}' is not an object in s3://{BUCKET}/")
        if not HEX.match(r["sha256"]):
            errs.append(f"line {n}: sha256 '{r['sha256']}' is not 64 lower-case hex")
        if r["kind"] not in KINDS:
            errs.append(f"line {n}: kind '{r['kind']}' is not one of {'|'.join(KINDS)}")
        src = r["source_sha256"] if r["source_sha256"] not in ("", "-") else "-"
        if src != "-" and not HEX.match(src):
            errs.append(f"line {n}: source_sha256 '{r['source_sha256']}' is not 64 hex, empty or -")
        if not re.match(r"^[A-Za-z0-9._-]+$", r["accession"]):
            errs.append(f"line {n}: accession '{r['accession']}'")
        rows.append({"role": role, "accession": r["accession"], "mate": mate, "bucket": bucket, "key": key,
                     "sha256": r["sha256"], "kind": r["kind"], "source_sha256": src})
    if not rows and not errs:
        errs.append("no input rows (header only): the input preparation (#90, part 2) has not written them")
    acc = {}
    for r in rows:
        acc.setdefault(r["role"], set()).add(r["accession"])
    for role in ("pe", "se"):
        if len(acc.get(role, ())) != 1:
            errs.append(f"role {role}: {len(acc.get(role, ()))} accessions, want exactly 1")
        for mate in (("1", "2") if role == "pe" else ("1",)):
            for kind in ("gz", "bgzf", "index"):
                k = [r for r in rows if r["role"] == role and r["mate"] == mate and r["kind"] == kind]
                if len(k) != 1:
                    errs.append(f"role {role} mate {mate}: {len(k)} {kind} rows, want 1")
    if errs:
        raise SystemExit(f"inputs: {path}:\n  " + "\n  ".join(errs))
    return rows


def accessions(rows):
    return " ".join(sorted({r["accession"] for r in rows if r["role"] == "pe"}) +
                    sorted({r["accession"] for r in rows if r["role"] == "se"}))


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if len(argv) < 2 or argv[0] not in ("check", "keys", "accessions"):
        sys.stderr.write(__doc__)
        return 2
    rows = load(argv[1])
    if argv[0] == "keys":
        for r in rows:
            if r['kind'] != 'fastq':   # the plain FASTQ is derived on the node, never staged
                print(f"s3://{r['bucket']}/{r['key']}")
    elif argv[0] == "accessions":
        print(accessions(rows))
    else:
        if "--accessions" in argv:
            want = " ".join(sorted(argv[argv.index("--accessions") + 1].split()))
            got = " ".join(sorted(accessions(rows).split()))
            if want != got:
                raise SystemExit(f"inputs: {argv[1]} names accessions '{got}', the spec's AK2_ACCESSIONS is '{want}'")
        for r in rows:
            print("\t".join(r[k] for k in ("role", "accession", "mate", "bucket", "key", "sha256", "kind", "source_sha256")))
    return 0


def self_test():
    import os
    import tempfile
    h = "a" * 64
    good = ["\t".join(HEADER)]
    for role, acc, mates in (("pe", "SRR1", ("1", "2")), ("single", "ERR2", ("-",))):
        for m in mates:
            for kind in ("gz", "bgzf", "index"):
                good.append("\t".join([role, acc, m, f"aws-kraken2/data/inputpath/{acc}_{m}.{kind}", h, kind, ""]))
    cases = {
        "good": (good, None),
        "header-only": (good[:1], "no input rows"),
        "missing": ([], "No such file"),
        "bad-bucket": (good[:1] + [good[1].replace("aws-kraken2/data", "s3://other-bucket/x")] + good[2:], "is not an object"),
        "no-index": ([l for l in good if not ("ERR2" in l and "\tindex\t" in l)], "0 index rows"),
        "bad-sha": (good[:1] + [good[1].replace(h, "zz")] + good[2:], "64 lower-case hex"),
    }
    ok = True
    with tempfile.TemporaryDirectory() as d:
        for name, (lines, want) in cases.items():
            p = os.path.join(d, name + ".tsv")
            if lines:
                open(p, "w").write("\n".join(lines) + "\n")
            try:
                rows = load(p)
                err = None
            except SystemExit as e:
                rows, err = None, str(e)
            passed = (err is None) if want is None else (err is not None and want in err)
            if want is None and rows:
                passed = passed and accessions(rows) == "SRR1 ERR2" and len(rows) == 9 and rows[-1]["mate"] == "1"
            print(f"{'ok  ' if passed else 'FAIL'} inputs {name}{'' if passed else ': ' + str(err)}")
            ok &= passed
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
