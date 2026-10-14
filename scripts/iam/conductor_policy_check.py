#!/usr/bin/env python3
"""Offline checks of the conductor's IAM documents (docs/conductor.md, "IAM"; in make test).

  conductor_policy_check.py check            the committed documents against the committed specs
  conductor_policy_check.py covers DOC...    exit 1, naming them, if any action a DOC (an IAM policy
                                             document, JSON) allows is outside the run-role boundary
  conductor_policy_check.py roles            the run roles the committed ladder specs need, one per line

check:
  - every document parses, and names only the account and results bucket of scripts/ak2.env;
  - iam:PassRole, iam:GetRole/GetInstanceProfile, iam:PutRolePolicy/AttachRolePolicy and RunInstances'
    ec2:InstanceProfile name exactly the roles (spawn-instance-<hash>, scripts/iam/spawn_role_name.py)
    that the committed runs/g3-l-*.json specs launch under, and nothing else;
  - PutRolePolicy and AttachRolePolicy hold only while the role carries the boundary
    (iam:PermissionsBoundary is ak2-spawn-instance-boundary);
  - the conductor policy grants no IAM write beyond those two, no wildcard Allow on a mutating action,
    and S3 on no bucket but the results bucket and RODA (read-only);
  - the boundary covers every action of what spawn 0.123.0 attaches to each run role: its scoped S3
    policy (from the spec), the spored baseline and AmazonSSMManagedInstanceCore v2 (so attaching it
    changes nothing the runs can do).
"""
import glob
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import spawn_role_name as SRN  # noqa: E402

POLICY = os.path.join(HERE, "conductor-policy.json")
TRUST = os.path.join(HERE, "conductor-trust.json")
BOUNDARY = os.path.join(HERE, "spawn-instance-boundary.json")
BOUNDARY_NAME = "ak2-spawn-instance-boundary"
RODA = "kraken2-ncbi-refseq-complete-v205"
# spawn 0.123.0 pkg/aws/iam.go sporedSelfManagementStatements, and AmazonSSMManagedInstanceCore v2's
# actions (iam get-policy-version, 2026-10-14): what every run role carries besides its S3 policy.
SPORED_BASELINE = ["ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:CreateTags", "ec2:DeleteTags",
                   "ec2:TerminateInstances", "ec2:StopInstances", "lambda:InvokeFunctionUrl", "fsx:DescribeFileSystems",
                   "fsx:CreateDataRepositoryAssociation", "fsx:DescribeDataRepositoryAssociations", "iam:CreateServiceLinkedRole"]
SSM_CORE = ["ssm:DescribeAssociation", "ssm:GetDeployablePatchSnapshotForInstance", "ssm:GetDocument", "ssm:DescribeDocument",
            "ssm:GetManifest", "ssm:GetParameter", "ssm:GetParameters", "ssm:ListAssociations", "ssm:ListInstanceAssociations",
            "ssm:PutInventory", "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult", "ssm:UpdateAssociationStatus",
            "ssm:UpdateInstanceAssociationStatus", "ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
            "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage", "ec2messages:GetEndpoint",
            "ec2messages:GetMessages", "ec2messages:SendReply"]


def env_value(key):
    with open(os.path.join(ROOT, "scripts", "ak2.env")) as f:
        for line in f:
            m = re.match(r"^%s=\"?([^\"\s]+)\"?" % re.escape(key), line)
            if m:
                return m.group(1)
    raise SystemExit("conductor_policy_check: %s not in scripts/ak2.env" % key)


def as_list(x):
    return x if isinstance(x, list) else [x]


def statements(doc):
    return [s for s in doc.get("Statement", []) if s.get("Effect") == "Allow"]


def actions_of(doc):
    out = set()
    for s in statements(doc):
        out.update(a.lower() for a in as_list(s.get("Action", [])))
    return out


def run_roles():
    out = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "runs", "g3-l-*.json"))):
        with open(f) as fh:
            out.setdefault(SRN.role_name(json.load(fh), env_value("AK2_RESULTS_BUCKET_us_west_2")), []).append(os.path.relpath(f, ROOT))
    return out


def missing(boundary, doc):
    """Actions doc allows that no boundary statement names (exact names; the boundary has no wildcards)."""
    have = actions_of(boundary)
    return sorted(a for a in actions_of(doc) if a not in have)


def check():
    bad = []
    acct, bucket = env_value("AK2_ACCOUNT"), env_value("AK2_RESULTS_BUCKET_us_west_2")
    docs = {}
    for p in (POLICY, TRUST, BOUNDARY):
        with open(p) as f:
            text = f.read()
        docs[p] = json.loads(text)
        for a in set(re.findall(r"arn:aws:[a-z0-9-]+:[a-z0-9-*]*:([0-9]{12}):", text)):
            if a not in (acct, "966362334030"):   # 966362334030: spore.host's DNS updater (spawn's baseline)
                bad.append("%s names account %s, not %s" % (os.path.basename(p), a, acct))
        for b in set(re.findall(r"arn:aws:s3:::([a-z0-9.-]+)", text)):
            if b not in (bucket, RODA):
                bad.append("%s names bucket %s" % (os.path.basename(p), b))
    pol = docs[POLICY]
    roles = run_roles()
    want_roles = {"arn:aws:iam::%s:role/%s" % (acct, r) for r in roles}
    want_profiles = {"arn:aws:iam::%s:instance-profile/%s" % (acct, r) for r in roles}
    barn = "arn:aws:iam::%s:policy/%s" % (acct, BOUNDARY_NAME)
    seen_pass, seen_prof, iam_write = set(), set(), []
    for s in statements(pol):
        acts = [a.lower() for a in as_list(s["Action"])]
        res = set(as_list(s["Resource"]))
        cond = s.get("Condition", {})
        if "iam:passrole" in acts:
            seen_pass |= res
            if cond.get("StringEquals", {}).get("iam:PassedToService") != "ec2.amazonaws.com":
                bad.append("%s: iam:PassRole without iam:PassedToService ec2.amazonaws.com" % s.get("Sid"))
        if "ec2:runinstances" in acts and any(":instance/" in r for r in res):
            seen_prof.add(cond.get("StringEquals", {}).get("ec2:InstanceProfile"))
        for a in acts:
            if a.startswith("iam:") and a not in ("iam:passrole", "iam:getrole", "iam:getinstanceprofile"):
                iam_write.append(a)
                if cond.get("StringEquals", {}).get("iam:PermissionsBoundary") != barn:
                    bad.append("%s: %s without iam:PermissionsBoundary %s" % (s.get("Sid"), a, barn))
                if res - want_roles:
                    bad.append("%s: %s on %s, not only the run roles" % (s.get("Sid"), a, sorted(res - want_roles)))
            if a.startswith("iam:") and a in ("iam:getrole", "iam:getinstanceprofile") and res - want_roles - want_profiles:
                bad.append("%s: %s on %s" % (s.get("Sid"), a, sorted(res - want_roles - want_profiles)))
            if res == {"*"} and not re.match(r"^(ec2:describe\*|pricing:|servicequotas:getservicequota|account:getaccountinformation)", a):
                bad.append("%s: %s on Resource *" % (s.get("Sid"), a))
            if a.startswith("s3:") and any(r.startswith("arn:aws:s3:::%s" % RODA) for r in res) and \
                    a not in ("s3:getobject", "s3:listbucket", "s3:getbucketlocation", "s3:getbucketrequestpayment"):
                bad.append("%s: %s on RODA (read-only)" % (s.get("Sid"), a))
    if seen_pass != want_roles:
        bad.append("iam:PassRole names %s; the committed ladder specs need exactly %s" % (sorted(seen_pass), sorted(want_roles)))
    if seen_prof != want_profiles:
        bad.append("RunInstances ec2:InstanceProfile %s; the specs need %s" % (sorted(map(str, seen_prof)), sorted(want_profiles)))
    if sorted(set(iam_write)) != ["iam:attachrolepolicy", "iam:putrolepolicy"]:
        bad.append("IAM writes %s: want only iam:PutRolePolicy and iam:AttachRolePolicy" % sorted(set(iam_write)))
    tr = docs[TRUST]["Statement"]
    if len(tr) != 1 or tr[0]["Principal"] != {"Service": "ec2.amazonaws.com"} or \
            tr[0].get("Condition", {}).get("StringEquals", {}).get("aws:SourceAccount") != acct:
        bad.append("conductor-trust.json: want EC2 in account %s only" % acct)
    bnd = docs[BOUNDARY]
    for r, specs in sorted(roles.items()):
        with open(os.path.join(ROOT, specs[0])) as f:
            inline = SRN.inline_policy(json.load(f), bucket)
        attached = {"Statement": [{"Effect": "Allow", "Action": SPORED_BASELINE + SSM_CORE, "Resource": "*"}]}
        for doc in ([json.loads(inline)] if inline else []) + [attached]:
            m = missing(bnd, doc)
            if m:
                bad.append("boundary %s does not cover %s of %s's policies (%s)" % (BOUNDARY_NAME, m, r, specs[0]))
    for b in bad:
        print("conductor_policy_check: FAIL %s" % b)
    print("conductor_policy_check: %s: %d run role(s) %s (%d ladder spec(s)); policy, trust and boundary %s" % (
        "ok" if not bad else "FAILED", len(roles), ",".join(sorted(roles)), sum(len(v) for v in roles.values()),
        "consistent" if not bad else "INCONSISTENT"))
    return 1 if bad else 0


def main(a):
    if a == ["check"]:
        return check()
    if a == ["roles"]:
        for r in sorted(run_roles()):
            print(r)
        return 0
    if a[:1] == ["covers"] and len(a) > 1:
        with open(BOUNDARY) as f:
            bnd = json.load(f)
        out = 0
        for p in a[1:]:
            with open(p) as f:
                m = missing(bnd, json.load(f))
            if m:
                print("conductor_policy_check: %s allows %s, outside %s" % (p, ",".join(m), BOUNDARY_NAME))
                out = 1
        return out
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
