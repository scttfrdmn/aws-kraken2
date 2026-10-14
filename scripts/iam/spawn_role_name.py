#!/usr/bin/env python3
"""The IAM role (and instance profile) `spawn task run` gives a spec's instance, with no AWS call
(docs/conductor.md, "IAM").

  spawn_role_name.py [--results-bucket B] SPEC.json...   one line per spec: <role name>\t<spec>
  spawn_role_name.py --self-test

spawn 0.123.0 (cmd/task.go runTaskReal, taskStagingPolicy; pkg/aws/iam.go CreateOrGetInstanceProfile,
PredictedInstanceRoleName) names the role spawn-instance-<sha256("[]|[]||" + inline policy)[:8]>, where
the inline policy is built from the spec's inputs (none: run.sh refuses them), outputs[] buckets plus
the results bucket (PutObject) and resources.s3_read_write buckets (read-write). run.sh rewrites
${AK2_OUT}/ to the results bucket. The conductor may pass only the roles this prints
(scripts/iam/conductor-iam.sh), so a spec whose role is not in the policy fails at launch with
AccessDenied rather than running under an unreviewed role.
"""
import hashlib
import json
import os
import sys

sys.dont_write_bytecode = True
DEFAULT_BUCKET = "aws-kraken2-942542972736-us-west-2"


def _bucket(u):
    return u[5:].split("/")[0] if u.startswith("s3://") else ""


def _dedupe(xs):
    out = []
    for x in xs:
        if x and x not in out:
            out.append(x)
    return out


def _arns(bs, obj):
    return ",".join(json.dumps("arn:aws:s3:::" + b + ("/*" if obj else "")) for b in bs)


def inline_policy(spec, results_bucket):
    outs = []
    for m in spec.get("outputs") or []:
        for ep in (m.get("source", ""), m.get("destination", "")):
            outs.append(_bucket(ep.replace("${AK2_OUT}", "s3://%s/x" % results_bucket)))
    rw = _dedupe(_bucket(u) for u in (spec.get("resources") or {}).get("s3_read_write") or [])
    reads = _dedupe(_bucket(m.get("source", "")) for m in spec.get("inputs") or [])
    wr = _dedupe(_dedupe(outs) + [results_bucket])
    st = []
    if reads:
        st.append('{"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion"],"Resource":[%s]}' % _arns(reads, 1))
        st.append('{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":[%s]}' % _arns(reads, 0))
    if wr:
        st.append('{"Effect":"Allow","Action":["s3:PutObject"],"Resource":[%s]}' % _arns(wr, 1))
    if rw:
        st.append('{"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:DeleteObject"],"Resource":[%s]}' % _arns(rw, 1))
        st.append('{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":[%s]}' % _arns(rw, 0))
    return '{"Version":"2012-10-17","Statement":[' + ",".join(st) + "]}" if st else ""


def role_name(spec, results_bucket=DEFAULT_BUCKET):
    data = "[]|[]||" + inline_policy(spec, results_bucket)   # Go: "%v|%v|%s|%s" of nil, nil, "", inline
    return "spawn-instance-" + hashlib.sha256(data.encode()).hexdigest()[:8]


def self_test():
    # Observed on 2026-10-14: the c10 r8gd.48xlarge members (s3_read_write = the results bucket's
    # data/ prefix) run under instance-profile/spawn-instance-27cce928.
    spec = {"resources": {"s3_read_write": ["s3://%s/aws-kraken2/data/" % DEFAULT_BUCKET]}}
    got = role_name(spec)
    assert got == "spawn-instance-27cce928", got
    print("spawn_role_name: self-test ok (%s)" % got)


def main(a):
    if a == ["--self-test"]:
        self_test()
        return 0
    rb = DEFAULT_BUCKET
    if a[:1] == ["--results-bucket"]:
        rb, a = a[1], a[2:]
    if not a:
        print(__doc__, file=sys.stderr)
        return 2
    for f in a:
        with open(f) as fh:
            print("%s\t%s" % (role_name(json.load(fh), rb), os.path.relpath(f)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
