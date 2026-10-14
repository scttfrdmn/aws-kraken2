#!/usr/bin/env python3
"""The conductor's IAM by behaviour, through the IAM policy simulator (docs/conductor.md, "IAM").

  conductor_iam_verify.py CONDUCTOR_ROLE_ARN    (scripts/iam/conductor-iam-verify.sh; make conductor-iam runs it)

Every request the conductor's work makes (spawn task run's RunInstances, tags, PassRole and its
refresh of the run role; run.sh's S3, quota, price and AMI calls; the campaign's terminations) is
simulated against the role's attached policies with the condition context a real call carries, and
must be allowed. Each has a negative control that must be denied: another instance profile, task id,
region, image owner, role, bucket or prefix; an IAM write without the boundary or of anything else.
The run role's own requests are simulated too (its permissions boundary included, when attached):
what the runs do must still be allowed. stdout: JSON {cases:[...], passed, failed}; exit 1 on any
mismatch, 2 when the simulator cannot be called.
"""
import json
import subprocess
import sys

A = "942542972736"
RB = "aws-kraken2-942542972736-us-west-2"
RODA = "kraken2-ncbi-refseq-complete-v205"
RUN_ROLE = "spawn-instance-27cce928"
BARN = "arn:aws:iam::%s:policy/ak2-spawn-instance-boundary" % A
PROF = "arn:aws:iam::%s:instance-profile/%s" % (A, RUN_ROLE)
SSM_CORE = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
I = "arn:aws:ec2:us-west-2:%s:instance/i-0123456789abcdef0" % A
V = "arn:aws:ec2:us-west-2:%s:volume/vol-0123456789abcdef0" % A


def ctx(**kv):
    out = []
    for k, v in kv.items():
        k = k.replace("__", ":").replace("_SLASH_", "/").replace("_DASH_", "-")
        out.append({"ContextKeyName": k, "ContextKeyValues": [v], "ContextKeyType": "string"})
    return out


def c(name, want, action, resource, context=None, who="conductor"):
    return {"name": name, "want": want, "action": action, "resource": resource, "context": context or [], "principal": who}


AK2_LAUNCH = ctx(aws__RequestTag_SLASH_spawn__task_DASH_id="ak2-g3-20261014-000000-abcdef0-0000-n1-r0",
                 aws__RequestTag_SLASH_spawn__managed="true", ec2__InstanceProfile=PROF)
AK2_TAGGED = ctx(ec2__ResourceTag_SLASH_spawn__task_DASH_id="ak2-g3-20261014-000000-abcdef0-0000-n1-r0")
CASES = [
    c("describe instances, any region", "allowed", "ec2:DescribeInstances", "*"),
    c("RunInstances: an ak2 task's instance with the run role", "allowed", "ec2:RunInstances", I, AK2_LAUNCH),
    c("RunInstances: ... but with the conductor's own profile (recursion)", "denied", "ec2:RunInstances", I,
      ctx(aws__RequestTag_SLASH_spawn__task_DASH_id="ak2-g3-x", aws__RequestTag_SLASH_spawn__managed="true",
          ec2__InstanceProfile="arn:aws:iam::%s:instance-profile/ak2-conductor" % A)),
    c("RunInstances: ... but another task id", "denied", "ec2:RunInstances", I,
      ctx(aws__RequestTag_SLASH_spawn__task_DASH_id="other-x", aws__RequestTag_SLASH_spawn__managed="true", ec2__InstanceProfile=PROF)),
    c("RunInstances: ... but in us-east-1", "denied", "ec2:RunInstances", I.replace("us-west-2", "us-east-1"), AK2_LAUNCH),
    c("RunInstances: an ak2 task's volume", "allowed", "ec2:RunInstances", V,
      ctx(aws__RequestTag_SLASH_spawn__task_DASH_id="ak2-g3-x")),
    c("RunInstances: an untagged volume", "denied", "ec2:RunInstances", V),
    c("RunInstances: a subnet in us-west-2", "allowed", "ec2:RunInstances", "arn:aws:ec2:us-west-2:%s:subnet/subnet-0123" % A),
    c("RunInstances: an Amazon image", "allowed", "ec2:RunInstances", "arn:aws:ec2:us-west-2::image/ami-0123", ctx(ec2__Owner="amazon")),
    c("RunInstances: someone else's image", "denied", "ec2:RunInstances", "arn:aws:ec2:us-west-2::image/ami-0123",
      ctx(ec2__Owner="123456789012")),
    c("CreateTags at launch", "allowed", "ec2:CreateTags", I, ctx(ec2__CreateAction="RunInstances")),
    c("CreateTags on an ak2 task's instance (run.sh's ak2: tags)", "allowed", "ec2:CreateTags", I, AK2_TAGGED),
    c("CreateTags on another instance", "denied", "ec2:CreateTags", I, ctx(ec2__ResourceTag_SLASH_spawn__task_DASH_id="other-x")),
    c("TerminateInstances: an ak2 task's instance (fail fast, wrong AZ)", "allowed", "ec2:TerminateInstances", I, AK2_TAGGED),
    c("TerminateInstances: an ak2 task's instance spawn put in another region", "allowed", "ec2:TerminateInstances",
      I.replace("us-west-2", "eu-west-1"), AK2_TAGGED),
    c("TerminateInstances: another instance", "denied", "ec2:TerminateInstances", I,
      ctx(ec2__ResourceTag_SLASH_spawn__task_DASH_id="other-x")),
    c("TerminateInstances: an untagged instance", "denied", "ec2:TerminateInstances", I),
    c("ReplaceIamInstanceProfileAssociation", "denied", "ec2:ReplaceIamInstanceProfileAssociation", "*"),
    c("ModifyInstanceAttribute", "denied", "ec2:ModifyInstanceAttribute", I, AK2_TAGGED),
    c("PassRole: the run role to EC2", "allowed", "iam:PassRole", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE),
      ctx(iam__PassedToService="ec2.amazonaws.com")),
    c("PassRole: the run role to Lambda", "denied", "iam:PassRole", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE),
      ctx(iam__PassedToService="lambda.amazonaws.com")),
    c("PassRole: another spawn role", "denied", "iam:PassRole", "arn:aws:iam::%s:role/spawn-instance-0346c413" % A,
      ctx(iam__PassedToService="ec2.amazonaws.com")),
    c("PassRole: the conductor role", "denied", "iam:PassRole", "arn:aws:iam::%s:role/ak2-conductor" % A,
      ctx(iam__PassedToService="ec2.amazonaws.com")),
    c("GetRole: the run role", "allowed", "iam:GetRole", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE)),
    c("GetInstanceProfile: the run profile", "allowed", "iam:GetInstanceProfile", PROF),
    c("PutRolePolicy: the run role while bounded", "allowed", "iam:PutRolePolicy", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE),
      ctx(iam__PermissionsBoundary=BARN)),
    c("PutRolePolicy: the run role without the boundary", "denied", "iam:PutRolePolicy", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE)),
    c("PutRolePolicy: the conductor role", "denied", "iam:PutRolePolicy", "arn:aws:iam::%s:role/ak2-conductor" % A,
      ctx(iam__PermissionsBoundary=BARN)),
    c("AttachRolePolicy: SSM core on the run role while bounded", "allowed", "iam:AttachRolePolicy",
      "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE), ctx(iam__PolicyARN=SSM_CORE, iam__PermissionsBoundary=BARN)),
    c("AttachRolePolicy: AdministratorAccess on the run role", "denied", "iam:AttachRolePolicy",
      "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE), ctx(iam__PolicyARN="arn:aws:iam::aws:policy/AdministratorAccess",
                                                      iam__PermissionsBoundary=BARN)),
    c("DeleteRolePermissionsBoundary: the run role", "denied", "iam:DeleteRolePermissionsBoundary",
      "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE), ctx(iam__PermissionsBoundary=BARN)),
    c("CreateRole", "denied", "iam:CreateRole", "arn:aws:iam::%s:role/spawn-instance-ffffffff" % A),
    c("S3: put a payload under aws-kraken2/", "allowed", "s3:PutObject", "arn:aws:s3:::%s/aws-kraken2/g3/x/payload.sh" % RB),
    c("S3: get under aws-kraken2/", "allowed", "s3:GetObject", "arn:aws:s3:::%s/aws-kraken2/g3/x/log/run.log" % RB),
    c("S3: tag under aws-kraken2/", "allowed", "s3:PutObjectTagging", "arn:aws:s3:::%s/aws-kraken2/g3/x/payload.sh" % RB),
    c("S3: abort an upload under aws-kraken2/", "allowed", "s3:AbortMultipartUpload", "arn:aws:s3:::%s/aws-kraken2/g3/x/out/a" % RB),
    c("S3: delete spawn's completion record", "allowed", "s3:DeleteObject",
      "arn:aws:s3:::%s/aws-kraken2/g3/x/spawn/ak2-g3-x/completion.json" % RB),
    c("S3: delete a manifest", "denied", "s3:DeleteObject", "arn:aws:s3:::%s/aws-kraken2/g3/x/manifest.json" % RB),
    c("S3: put outside aws-kraken2/", "denied", "s3:PutObject", "arn:aws:s3:::%s/other/x" % RB),
    c("S3: list the results bucket", "allowed", "s3:ListBucket", "arn:aws:s3:::%s" % RB),
    c("S3: list versions of the results bucket", "allowed", "s3:ListBucketVersions", "arn:aws:s3:::%s" % RB),
    c("S3: list uploads of the results bucket", "allowed", "s3:ListBucketMultipartUploads", "arn:aws:s3:::%s" % RB),
    c("S3: the results bucket's Payer", "allowed", "s3:GetBucketRequestPayment", "arn:aws:s3:::%s" % RB),
    c("S3: read RODA", "allowed", "s3:GetObject", "arn:aws:s3:::%s/Kraken2_RefSeqCompleteV205/hash.k2d" % RODA),
    c("S3: RODA's Payer", "allowed", "s3:GetBucketRequestPayment", "arn:aws:s3:::%s" % RODA),
    c("S3: write RODA", "denied", "s3:PutObject", "arn:aws:s3:::%s/x" % RODA),
    c("S3: another bucket", "denied", "s3:GetObject", "arn:aws:s3:::cookbook-942542972736-us-west-2/x"),
    c("pricing (truffle)", "allowed", "pricing:GetProducts", "*"),
    c("service quotas (quota_check.sh)", "allowed", "servicequotas:GetServiceQuota", "*"),
    c("the AL2023 AMI parameter", "allowed", "ssm:GetParameter",
      "arn:aws:ssm:us-west-2::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"),
    c("an account SSM parameter", "denied", "ssm:GetParameter", "arn:aws:ssm:us-west-2:%s:parameter/secret" % A),
    c("assume another role", "denied", "sts:AssumeRole", "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE)),
    # The run role: what the runs do is still allowed (with its boundary, once attached), and no more.
    c("run role: put under the results bucket", "allowed", "s3:PutObject", "arn:aws:s3:::%s/aws-kraken2/g3/x/out/a" % RB, who="run"),
    c("run role: read the cohort data", "allowed", "s3:GetObject", "arn:aws:s3:::%s/aws-kraken2/data/cohort/a" % RB, who="run"),
    c("run role: spored reads its tags", "allowed", "ec2:DescribeTags", "*", who="run"),
    c("run role: spored terminates itself", "allowed", "ec2:TerminateInstances", I, ctx(ec2__ResourceTag_SLASH_spawn__managed="true"),
      who="run"),
    c("run role: SSM agent", "allowed", "ssm:UpdateInstanceInformation", "*", who="run"),
    c("run role: launch an instance", "denied", "ec2:RunInstances", I, AK2_LAUNCH, who="run"),
    c("run role: write RODA", "denied", "s3:PutObject", "arn:aws:s3:::%s/x" % RODA, who="run"),
]


def simulate(principal, case):
    req = {"PolicySourceArn": principal, "ActionNames": [case["action"]], "ResourceArns": [case["resource"]]}
    if case["context"]:
        req["ContextEntries"] = case["context"]
    r = subprocess.run(["aws", "iam", "simulate-principal-policy", "--cli-input-json", json.dumps(req), "--output", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip()[:300]
    res = json.loads(r.stdout)["EvaluationResults"][0]
    return res["EvalDecision"], ";".join(s.get("SourcePolicyId", "?") for s in res.get("MatchedStatements", []))


def main(a):
    if len(a) != 1 or not a[0].startswith("arn:aws:iam::"):
        print(__doc__, file=sys.stderr)
        return 2
    principals = {"conductor": a[0], "run": "arn:aws:iam::%s:role/%s" % (A, RUN_ROLE)}
    out, bad, broken = [], 0, 0
    for case in CASES:
        got, why = simulate(principals[case["principal"]], case)
        if got is None:
            broken += 1
        good = (got == "allowed") == (case["want"] == "allowed") and got is not None
        bad += 0 if good else 1
        out.append(dict(case, got=got, matched=why, ok=good))
        print("conductor-iam-verify: %s %-9s want %-7s %-40s %s" % ("ok  " if good else "FAIL", case["principal"], case["want"],
                                                                 case["action"], case["name"]), file=sys.stderr)
    print(json.dumps({"simulator": "iam simulate-principal-policy", "principals": principals, "cases": out,
                      "passed": len(out) - bad, "failed": bad}))
    print("conductor-iam-verify: %d of %d cases as expected" % (len(out) - bad, len(out)), file=sys.stderr)
    return 2 if broken == len(out) else (1 if bad else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
