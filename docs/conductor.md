# The conductor: ladder campaigns off the laptop (#77)

**What:** a small Graviton instance that runs `make ladder-campaign` in place of the laptop, so the
laptop can sleep. It is launched through `make run` like any run, so it gets the preamble's
streaming, region and Payer asserts, a TTL and a `cost_limit`. It clones the run's commit,
installs pinned tools, and runs the campaign under its own instance role. It stages every result
to S3 as it goes. On the laptop, `make harvest` fetches, verifies and installs the staged results,
then prints what to commit.

```bash
make conductor-iam                                   # once, and after any change to scripts/iam/ (laptop; creates IAM)
make conductor-spec COHORT=10 [RUNGS=S1,O0] [REPS=2] [DRY_RUN=1] [DRY_MAKE_RUN=1] [TTL=<min>]   # runs/conductor.json
git commit runs/conductor.json && git push           # the conductor clones the pushed commit
nohup make run GATE=conductor SPEC=runs/conductor.json > /tmp/conductor.out 2>&1 &   # the launch; laptop may then sleep
make ladder-campaign-drain CAMPAIGN=<conductor run id> REASON=...   # stop launching; in-flight runs finish
make harvest CAMPAIGN=<conductor run id>             # fetch, verify, install; prints the git add (commits nothing)
make rehearse-conductor                              # the local rehearsal (podman, no AWS)
```

The conductor's run id (`<yyyymmdd-hhmmss>-<sha7>`, printed by `make run`, and in
`results/conductor/<id>/`) is the campaign id everywhere: the staging prefix, the drain flag,
`finalised_by_run_id` and `make harvest`.

## The spec

`make conductor-spec` (`scripts/mkspec-conductor.sh`) writes `runs/conductor.json` from
`scripts/conductor.body.sh`, with the campaign's arguments in its `@PARAMS@` block, which travels
in the payload and not in env:
`COHORT=…; RUNGS="…"; REPS=…; CONCURRENCY=…; FAMILY_LIMITS="…"; DRY_RUN=…; DRY_MAKE_RUN=…; TTL_S=…`.
`OUT=runs/conductor-<x>.json` writes another name. run.sh ties `runs/conductor*.json` to
`GATE=conductor` in both directions.

- **Type:** `m8g.medium` by default (`TYPE=`): 1 Graviton vCPU, 4 GiB, $0.04488/h on demand
  (truffle 0.57.1, 2026-10-14). It is not burstable, so `cost_usd` is the bill. The 2 GiB types
  (`t4g.small` $0.0168/h, `c8g.medium` $0.03988/h) are tight for run.sh's `go build` of
  `scripts/udsize`. `t4g` is also burstable: unlimited-mode CPU credits are charged outside
  `cost_usd`.
- **TTL:** `AK2_MAX_TTL_S` / 60 minutes by default, which is 8 h. A longer campaign needs a higher
  `AK2_MAX_TTL_S`, and setting that is Scott's call. `cost_limit` is the truffle price × TTL
  (+ $0.005, to the cent).
- **Buckets:** `AK2_DATASETS` declares the RODA prefix and the results bucket's `aws-kraken2/`. The
  preamble's aws shim therefore allows the nested run.sh's Payer, head-object, payload and staging
  calls, and nothing else.
- **`DRY_RUN=1`:** the campaign only prints its plan. **`DRY_MAKE_RUN=1`:** before the campaign,
  `DRY_RUN=1 make run` of the cheapest committed `c<COHORT>` rung. That exercises spawn's sizing,
  the cost, quota and network checks, the user-data measure (`go build` of `scripts/udsize`),
  presigning and the pin identity, all under the instance role, and launches nothing.

Its cost is overhead. It lives in `results/conductor/<id>/manifest.json` (`cost_usd`). It carries no
ladder PARAMS (`params` is null), so `make g3-ladder` and the campaign's record never count it
against a rung.

## make run GATE=conductor

`scripts/run.sh` adds the following for the conductor gate:
- **Preconditions:** the whole tree must be clean, `results/` and untracked files included.
  Otherwise an uncommitted run dir would be missing from the record the conductor plans from, and
  would be planned again. `git fetch origin` must succeed, and HEAD must be on a remote branch:
  the conductor clones it from GitHub and holds no git credentials.
- **Credentials:** `spawn task run` gives every instance its own scoped role,
  `spawn-instance-<hash of its S3 policy>`, which can launch nothing. spawn 0.123.0 has no
  instance-profile field for `task run`. So run.sh replaces the instance's profile association
  with `ak2-conductor` straight after launch (`ec2 replace-iam-instance-profile-association`, with
  the laptop's credentials), records it as `manifest.conductor`, and terminates the instance if
  that fails. The body waits until IMDS and `sts get-caller-identity` show `ak2-conductor` before
  it does any AWS work: 120 tries 5 s apart, then exit 1.
- **Finalisation:** everything else is as for any run. The laptop's `make run` keeps polling the
  conductor's log. If the laptop sleeps, it resumes on wake: failed calls back off, and
  `AK2_POLL_GRACE_S` applies. If the laptop's `make run` dies, finish later with
  `scripts/refinalise.sh results/conductor/<id>`. That affects only the conductor's own record,
  never the campaign.

`run-multi.sh` refuses `GATE=conductor`: it is one instance.

## On the instance (`scripts/conductor.body.sh`)

Phases:
1. **setup:**
   - the role wait;
   - a `DRAIN` already in the staging prefix ends the body at once (exit 0, state
     `drained-before-start`);
   - `dnf install git jq make tar gzip unzip findutils perl-Digest-SHA python3` (`shasum` for
     run.sh);
   - the clone at the run id's sha7, checked against the full SHA;
   - upstream at the pin into `.oracle/src-<pin>`, which run.sh's pin identity needs;
   - the tools of `scripts/conductor.tools.tsv`, each verified by sha256: spawn 0.123.0 and
     truffle 0.57.1 from their GitHub releases, and Go 1.27.1 from go.dev. These are run.sh's
     `spawn version` and `scripts/udsize` pins.
2. **probe** (if `DRY_MAKE_RUN=1`): the dry run described above.
3. **campaign:** `make ladder-campaign COHORT=… [RUNGS=…] REPS=… CONCURRENCY=… [FAMILY_LIMITS=…] [DRY_RUN=1]`,
   teed to `campaign.log`. make reports any non-zero exit as 2, so the campaign's own exit is read
   from its `ladder-campaign: exit N` line.
4. **stage:** the last staging pass. `conductor.json` is then marked `ended`.

The aws CLI, git, jq, python3 and make come from the AMI's repositories. AL2023's repositories are
versioned with the AMI release, and the versions are recorded in `conductor.json` `tools`. The
aws CLI cannot be swapped for a pinned build: the preamble's allow-list shim is bound to the CLI it
found at start.

The campaign runs with this environment:
- `AK2_INSTANCE_ROLE=1`: `scripts/ak2.env` unsets `AWS_PROFILE`, so the CLI and the Go SDKs
  (spawn, truffle) use the instance role. The laptop's keys never leave the laptop.
- `AK2_FINALISED_BY=conductor` and `AK2_CONDUCTOR_RUN_ID=<id>`: run.sh records `finalised_by` and
  `finalised_by_run_id` in every manifest it finalises, before util.py, so the `util.json`
  citations stay intact. run-multi.sh records them in `cohort.json`.
- `AK2_CAMPAIGN_DRAIN=$HOME/ak2c/DRAIN`: the campaign's local flag.
- `AK2_CAMPAIGN_DEADLINE`: the instance's `spawn:ttl-deadline` (the TTL_S parameter if the tag
  cannot be read) minus 900 s. The campaign launches nothing whose TTL plus 1800 s of finalisation
  would end after it, and drains instead (docs/ladder.md, "Draining").

Body exit: 0 when the campaign exits 0 or 4 (drained); otherwise the campaign's exit; 1 for a
setup failure.

**Laptop-only assumptions, and what replaces them here:**

| assumption | on the conductor |
|---|---|
| `AWS_PROFILE=aws` | unset by `AK2_INSTANCE_ROLE=1` (scripts/ak2.env) |
| macOS `shasum` | `perl-Digest-SHA` |
| upstream checkout for the pin identity | cloned at setup |
| spawn, truffle, go on PATH | pinned, sha256-checked |
| a clean, pushed tree | the clone is that commit; the campaign writes only `results/` and appends to `scripts/lib/g3_defects.tsv` at its end |
| `make orphans` sees only runs | it sees the conductor too: see "Orphans and quota" |
| podman, git push | used by neither the run path nor the campaign |

`date`, `stat` and `mktemp` are used portably on the run path (`-u +FORMAT` only). The body itself
is Linux-only: it uses `date -d` and `stat -c`.

## Staging, and the drain flag

The staging prefix is `s3://<results bucket>/aws-kraken2/results-staging/<id>/`
(`AK2_STAGING_DIR`). It is written every `STAGE_EVERY` s (60) and after the campaign:

| object | what |
|---|---|
| `conductor.json` | state, commit, params, campaign ts and rc, drain, deadline, tool versions, `ended` |
| `tree/<path>` | every file the campaign added to the clone (`git status`: a new directory is synced whole) |
| `changes.tsv` | sha256, bytes and path of every one of them |
| `tracked.patch` | `git diff` of tracked files it changed (the capacity rows appended to `g3_defects.tsv`) |
| `campaign.log` | the campaign's output |
| `DRAIN` | written by `make ladder-campaign-drain CAMPAIGN=<id>` |

The conductor's own run log streams to its run prefix as for any run, through the preamble.

**Drain.** Every `DRAIN_POLL_S` s (30) the body copies `…/<id>/DRAIN` to the campaign's local flag.
The campaign then launches nothing more. It lets the runs in flight finish, finalises them and
checks orphans as normal, writes its summary, and exits 4. The body stages everything and exits 0.

**Kill switch.** Terminating the conductor stops all new launches. Runs in flight still
self-terminate at their own TTL and `cost_limit` (spored). Their drivers died with the conductor,
so their manifests are not finalised. `make harvest PARTIAL=1` shows what was staged. After that:
1. run `make orphans`;
2. finish each staged run dir with `scripts/refinalise.sh`. It fetches the run prefix. Its
   `finalised_by` is then unset, so harvest reports it.

## Orphans and quota

The conductor is an ak2 instance (`spawn:task-id ak2-conductor-…`, `ak2:gate conductor`):
- **Global `make orphans`:** a conductor within its TTL is listed as `CONDUCTOR` and not counted.
  This holds on the laptop, and inside the campaign, which runs make orphans before and after
  every run. A conductor past its TTL + 15 min, or with a `spawn:ttl-deadline` that is missing or
  does not parse, counts like any other instance.
- **Scoped (`--own`) checks of member runs:** these never count it. It appears in `others[]` with
  `flag: conductor`.
- **`quota_check.sh`:** counts the conductor's vCPU (1, in the Standard family), because AWS
  counts it.

The stub test is `scripts/lib/orphans_conductor_test.sh` (in make test).

## IAM

`make conductor-iam` (`scripts/iam/conductor-iam.sh`) runs on the laptop. It is idempotent, and
everything it creates or touches is tagged `project=aws-kraken2` and `ak2:project=aws-kraken2`:

| resource | from |
|---|---|
| role `ak2-conductor` (EC2 trust, `aws:SourceAccount` 942542972736) | `scripts/iam/conductor-trust.json` |
| its inline policy `ak2-conductor-policy` | `scripts/iam/conductor-policy.json` |
| instance profile `ak2-conductor` holding the role | |
| managed policy `ak2-spawn-instance-boundary` | `scripts/iam/spawn-instance-boundary.json` |
| that boundary on each run role the committed ladder specs launch under (today one: `spawn-instance-27cce928`) | |

It records the ARNs, document sha256s and the simulation in `results/iam/conductor-<ts>.json`. It
exits 0 when everything is done and verified, and 3 when the boundary is pending (below).

**The policy, statement by statement:**
- `ec2:Describe*` everywhere.
- `RunInstances`:
  - instances in us-west-2 only, tagged `spawn:task-id ak2-*` and `spawn:managed true` at launch,
    with exactly the run role's instance profile (`ec2:InstanceProfile`);
  - their volumes;
  - subnets, ENIs, security groups and key pairs in us-west-2;
  - Amazon-owned images only.
- `CreateTags`: at launch only; and `CreateTags`, `DeleteTags`, `StopInstances` and
  `TerminateInstances` on instances tagged `spawn:task-id ak2-*`. The region is open there, so a
  misplaced launch can be terminated. This also covers the conductor's own spored.
- `iam:PassRole` of exactly the run role, to EC2 only.
- `iam:GetRole` and `GetInstanceProfile` on it.
- `iam:PutRolePolicy` and `iam:AttachRolePolicy` on it, which `spawn task run` performs on every
  launch:
  - only while the role carries `ak2-spawn-instance-boundary` (`iam:PermissionsBoundary`);
  - `AttachRolePolicy` only for `AmazonSSMManagedInstanceCore`.
- S3 on the results bucket's `aws-kraken2/*`:
  - get, put, tags and multipart abort;
  - delete only `*/spawn/*`, spawn's completion records;
  - bucket listing, versions, uploads, Payer and versioning.
- RODA (`kraken2-ncbi-refseq-complete-v205`) read-only.
- `pricing:*` reads, `servicequotas:GetServiceQuota` and `account:GetAccountInformation`.
- The public `/aws/service/*` SSM parameters, for the AMI.
- spored's DNS updater.

No IAM create, no other role, no other bucket. `CreateRole` is not granted, so a spec whose S3
policy would need a new `spawn-instance-<hash>` fails at launch. Its role must first be created by
a laptop launch and added to the policy. `conductor_policy_check.py check` (in make test) fails
when the committed specs need a role the policy does not name.

**Why the boundary:** `spawn task run` rewrites the run role's inline policies on every launch, so
a conductor with unconditioned `PutRolePolicy` could write any policy into a role it may pass to
an instance it may launch. The boundary caps that role at what spawn gives it today:
- its scoped S3 policy;
- the spored baseline;
- `AmazonSSMManagedInstanceCore` v2.

The conductor may edit the role only while the boundary is on it.

Attaching the boundary changes nothing a run can do. `conductor-iam.sh` checks, live, that every
action of the role's current policies lies inside the boundary. Still, it attaches the boundary
only when no instance is using the role. Otherwise it reports `PENDING` and exits 3. Until then
the conductor can plan and dry-run, but its rung launches fail at `PutRolePolicy`. After a spawn
upgrade, rerun `make conductor-iam`: a baseline grown beyond the boundary is reported, not
attached.

**Verification by behaviour:**
- `make conductor-iam-verify` (`scripts/iam/conductor_iam_verify.py`): 59 requests through the IAM
  policy simulator, each allowed request with its denied negative control. They cover another
  profile, task id, region, image owner, role, bucket and prefix; IAM writes without the boundary;
  `CreateRole`; and the run role's own requests under the boundary. `make conductor-iam` runs it.
- `CUSTOM=1` simulates the committed documents before anything exists (`simulate-custom-policy`).
  On 2026-10-14 it passed 59 of 59.

## Harvest

`make harvest CAMPAIGN=<id> [PARTIAL=1]` (`scripts/harvest.sh`, `scripts/lib/harvest_check.py`)
first does `aws s3 sync` of the staging prefix (not `DRAIN`) to a scratch dir. It installs nothing
unless every check below holds:
- `conductor.json` names the campaign and is `ended` (`PARTIAL=1` reports a conductor still
  running instead);
- `changes.tsv` and `tree/` agree file for file: sha256, size, and nothing extra;
- no staged file would overwrite a different file in the repo;
- every staged run dir:
  - is finalised;
  - has `finalised_by` conductor with this `finalised_by_run_id`, and the conductor's commit;
  - its `spec_sha256` is both its `spec.json`'s and the committed spec's at that commit;
  - every `tables/util.json` input has the sha256 it cites: staged, else in the repo, else at the
    commit;
- every staged `cohort.json` is `finalised_by` conductor, with all its members staged;
- the campaign tsv is staged when a campaign ran:
  - every row names a run dir that exists (staged for launched rows; staged or in the repo for
    skips) or none;
  - every staged cohort dir is in it.

Then it:
1. copies the files in;
2. checks and applies `tracked.patch` (`git apply --check` first);
3. tags the staged objects;
4. prints the `git add` (each new path as git status shows it) and a commit message with the spend
   and the conductor overhead.

It says whether `results/conductor/<id>/` (written by the laptop's `make run`) is here and
finalised. It commits nothing. Exit: 0 installed, 1 refused (nothing installed), 2 fetch or patch
failure.

## The rehearsal: `make rehearse-conductor`

This is `scripts/lib/conductor_rehearse.sh`, about 2 min, with podman and no AWS. It runs exactly
what run.sh launches (the stub under `bash -e -c`, the preamble, the body) on AL2023 containers.
The stand-ins are at the edges only:
- IMDS, with `iam/info`;
- an aws CLI over a shared directory standing in for the bucket;
- version stubs for spawn, truffle and go;
- the campaign's `AK2_CAMPAIGN_*` seams. The run stub writes a cohort dir as run-multi.sh does,
  with `finalised_by` from the env.

The container clones a scratch commit of HEAD whose record lacks the c1 S2a and S5 runs, so the
campaign has something to launch. The rounds are listed in the script's header:
- **full:** run, stage, harvest into a clone, harvest again; a tampered file and a missing
  `finalised_by` are each refused;
- **drain:** DRAIN mid-run; exit 4 after the in-flight run is recorded and harvested;
- **early:** DRAIN before start;
- **plan:** DRY_RUN with the real `make g3-ladder` on AL2023's python 3.9;
- **norole:** the role never arrives; exit 1, still staged.

**The AWS rehearsal** comes first, before the conductor drives any real rung (the issue's point 6):
`runs/conductor.json` as committed, which is
`make conductor-spec COHORT=10 DRY_RUN=1 DRY_MAKE_RUN=1 TTL=60` (m8g.medium, TTL 60m,
`cost_limit` $0.05). It launches nothing. With the commit pushed and `make conductor-iam` done:

```bash
make run GATE=conductor SPEC=runs/conductor.json     # waits for the conductor to end (about 15-25 min)
make harvest CAMPAIGN=<its run id>                   # a plan-only campaign stages no tree: harvest verifies conductor.json
make orphans
```

Read in its log (`results/conductor/<id>/log/run.log`):
- the role line;
- every `tool … sha256 ok`;
- the probe's `make run (multi): DRY_RUN=1` sizing plan, `quota_check: ok` and the user-data line;
- the c10 plan;
- `campaign exit 0`.

## Failure looks like

| symptom | cause |
|---|---|
| `make run: the conductor needs the instance profile ak2-conductor`, instance terminated | `make conductor-iam` was not run, or the laptop lacks `ec2:ReplaceIamInstanceProfileAssociation` / `iam:PassRole` on ak2-conductor |
| body exit 1 `never got the ak2-conductor role` | the association was not replaced (see the run.sh line above it) |
| `checkout <sha7> failed (is it pushed?)` | run.sh refuses an unpushed HEAD, so a force-push happened since |
| probe or a rung fails `AccessDenied … PutRolePolicy` | the boundary is PENDING: rerun `make conductor-iam` with nothing in flight |
| `AccessDenied … PassRole` / `RunInstances` | the spec needs a run role the policy does not name (`conductor_policy_check.py check`) |
| campaign exit 4 with launches left, `deadline:` | the conductor's TTL would end first; launch a new conductor for the rest (done runs are skipped) |
| `harvest: FAIL …` | the line names the run dir and the check; nothing was installed |
