# make run GATE=… SPEC=…

**What:** launches one checked-in TaskSpec from `runs/` through `spawn task run`. It enforces
Law 4 so that no spec can skip it, records `results/<gate>/<run-id>/`, and runs `make orphans`
at the end. Backed by `scripts/run.sh`, `scripts/preamble.sh` and `scripts/ak2.env`. The
spore.host details are in [spore-host.md](spore-host.md).

```bash
make run GATE=g0a SPEC=runs/g0a.json            # launch, wait, fetch, finalise, orphan check
make run GATE=g0a SPEC=runs/g0a.json DRY_RUN=1  # validate + spawn sizing plan, launch nothing
```

## Inputs

- `GATE`: lowercase alphanumeric (`g0a`, `g1`, …).
- `SPEC`: `runs/<name>.json`, committed. `run.sh` also refuses to start if
  `git status --porcelain -- scripts runs cmd internal upstream go.mod go.sum Makefile` shows
  anything, because the manifest cites one commit for the harness, spec and decoders. It is a
  spawn TaskSpec with these constraints:
  - `lifecycle.ttl` must match `^([0-9]+[hms])+$`, be non-zero and be at most `AK2_MAX_TTL_S`
    (4 h). `lifecycle.cost_limit` must be positive and at most `AK2_MAX_COST_USD` ($5). Both
    ceilings are in `ak2.env`. `on_complete` is forced to `terminate`;
  - `command` is `["bash","-c","<script>"]`. `container`, `inputs[]` and `results_prefix` are
    refused: spawn would stage inputs before the preamble's region assert, so use `ak2_stage`;
  - the script may not turn errexit back on (`set -e`, `set -euo …`, `set -o errexit`,
    `bash -e`, `shopt -so errexit`, a `-e` shebang); Law 4 says `set +e`;
  - `placement.{ami,volumes,fsx_lustre_id,efs_id,…_mount_point}` are refused (the AMI is spawn's
    auto-selection, recorded in the manifest), and so are `resources.purchase` other than
    `on_demand` and `resources.fallback`. Spot is a later lever, and `cost_usd` assumes
    on-demand;
  - every `outputs[].destination` must start with `${AK2_OUT}/`, which becomes `<run prefix>/out/`;
  - `env` is an allow-list: only the keys below. Anything else the script needs it sets itself;
    `BASH_ENV`, `ENV` and the harness's own `AK2_*` keys are therefore refused;
  - `env.AK2_REGION`: the launch region;
  - `env.AK2_ACCESSIONS`: space-separated sample accessions (`""` for none). The key must be present;
  - `env.AK2_DATASETS`: the **bucket allow-list**, as space-separated `s3://` URIs. An object URI
    gets its ETag, VersionId and size recorded in the manifest; a URI ending in `/` declares a
    bucket or prefix only. Every declared bucket is region- and Payer-checked;
  - `env.AK2_ALLOW_NO_BUCKETS="1"`: required if `AK2_DATASETS` is empty;
  - `env.AK2_ALLOW_REQUESTER_PAYS="1"`: required to touch a Requester-pays bucket;
  - `env.BUCKET_REGION` (optional): declares the bucket region explicitly; it must still match;
  - `resources.s3_read_write` (spawn's IAM grant, full read-write) may name only declared
    buckets. Use it only when `ak2_stage` needs a private bucket.
- Optional `scripts/post/<name>.sh` (same basename as the spec): run locally after fetch as
  `scripts/post/<name>.sh <run-dir>`. It may read only the run dir, taking object identities from
  `manifest.json`, and writes `decoded/` and `tables/`. It can be re-run on an existing run dir
  and records the commit it ran at.

## The bucket allow-list

The allowed set is the declared buckets plus the results bucket. It is enforced three ways:

1. **Statically:** every `s3://<bucket>` literal and every `--bucket` or `--copy-source`
   literal in the script (a leading `/` is stripped) must be in the allowed set.
2. **At run time:** the preamble writes a shim, `/tmp/ak2-bin/aws`, and puts it first on `PATH`.
   The shim has the allowed set and the real CLI's absolute path baked in. Any call with an
   argument equal to `s3` or `s3api` that names a bucket outside the set is refused (rc 126).
   The shim checks `s3://X`, `--bucket X`, `--bucket=X` and `--copy-source [/]X/…`. Everything
   else is `exec`ed to the real CLI. This covers anything that finds `aws` through `PATH`: the
   script, `env`, `xargs`, `timeout`, `sh -c`, and Python or other subprocesses.
3. **Region:** every declared bucket's region must equal `AK2_REGION`, checked on the launch
   host and again on the instance.

**Not covered:**
- `curl` and SDKs (boto3, the Go SDK, and so on);
- the real CLI called by absolute path;
- `sudo aws`, since sudo resets `PATH`;
- buckets passed inside `--cli-input-json`;
- a process that rewrites `PATH`.

The allow-list is a guard against mistakes, not a sandbox: keep data I/O on the `aws` CLI.

## The spec body's helpers

| helper | what |
|---|---|
| `ak2_say MSG` | timestamped log line |
| `ak2_phase NAME` | marks the start of a phase; `run.sh` derives `tables/phases.tsv` (phase, start, seconds, cold) and `manifest.phases`. A phase still running when the run was killed hard has empty seconds (`null`) |
| `ak2_req OP N [BUCKET]` | records N S3 requests of type OP in the current phase; becomes `out/requests.tsv`, `tables/requests.tsv` and `manifest.requests`. OP must be a non-empty word and N a non-negative integer; otherwise it logs an error and a run that would have exited 0 exits 96 |
| `ak2_stage SRC DST` | stage an input from a declared bucket (signed, then anonymous); `SRC` ending in `/` is recursive |
| `ak2_push FILE [NAME]` | stream a result to `<run prefix>/out/NAME` now |
| `ak2_drop_caches` | required before every cold rung. Marks the **next** `ak2_phase` as `cold=yes`. If the preflight found `drop_caches_ok=false`, or the drop fails, it ends the run with exit 95; a warm rung is never mislabelled cold |

The helpers are `readonly -f`. The body must not replace the EXIT/TERM/HUP/INT traps.
- On any exit, including a process-group SIGTERM at shutdown, the finish handler logs the real
  status (143 for TERM, 129 for HUP, 130 for INT) and pushes `run.log` and `requests.tsv`.
  It writes straight to the log file, so a dead tee cannot SIGPIPE it.
- The tee ignores TERM/HUP. The preamble checks that it started (within 5 s) and exits 97 if not.
- A bare `wait` is safe, because the tee and the pusher are disowned.

Every spec must count its requests with `ak2_req`; `run.sh` warns if none were recorded.

## What it does

1. Validates the spec as above. Then it checks the region of each declared bucket
   (`x-amz-bucket-region`) and of the results bucket, the static literals, and each declared
   bucket's Payer from the launch host. An `UNKNOWN` Payer is refused, and so is `Requester`
   without the opt-in. It runs head-object on every declared object; a failure is refused.
2. Picks `RUN_ID=<UTC yyyymmdd-hhmmss>-<short sha>` and `task_id=ak2-<gate>-<run-id>`, and writes
   `spec.json` (the original) and `spec.resolved.json` (preamble prepended, harness env added).
3. Writes `manifest.json`: commit (and dirty flag), upstream pin, spec sha256, tool versions, TTL
   and cost limit, accessions, allowed buckets, datasets (ETag, VersionId, size), Payer per bucket.
4. Runs `spawn task run --dry-run` (saved as `spawn-plan.txt`) and pins the planned type into
   `spec.resolved.json` as `resources.instance_type`. spawn sizing takes about 4 minutes per
   call, and the launch must be the box the plan priced. It then launches with `-o json`
   (`launch.json`) and tags the instance `ak2:project/gate/run-id`. **If spawn reports a region
   other than `AK2_REGION`, it terminates the instance, runs orphans and exits 2.** Otherwise it
   adds instance type and count, AMI, AZ, launch time and the truffle on-demand price.
5. Tails `<run prefix>/log/run.log` every 15 s until `completion.json` appears, the instance
   terminates, or TTL + 3 min passes. It then waits for `terminated` and copies the run prefix
   into the run dir.
6. Derives `tables/phases.tsv` and `tables/requests.tsv`, then finalises the manifest with the
   completion record, preflight, phases, requests, stop time (from `StateTransitionReason`),
   billed seconds and `cost_usd`. `cost_usd` is the truffle price × (terminate − launch) with a
   60 s minimum: compute only, an estimate rather than a bill. If any manifest update fails after
   launch, the run continues and exits 4.
7. Runs `scripts/post/<name>.sh` if present, then `scripts/orphans.sh`.

On the instance, `preamble.sh` runs first:
1. `$-` before and after `set +e`.
2. IMDSv2 region/AZ/type/AMI, then the region assert against every declared bucket (exit 97 on
   mismatch).
3. Payer per bucket. Requester without opt-in is fatal; `UNKNOWN` is a warning, because the
   instance role cannot read our own buckets' Payer and the launch host already verified it.
4. A `drop_caches` probe (`sudo -n` plus a writable `/proc/sys/vm/drop_caches`), recorded as
   `drop_caches_ok`, then `preflight.json`.
5. The log and `requests.tsv` push every 5 s (fixed), plus a final push on exit.

## Outputs

`results/<gate>/<run-id>/`: `manifest.json`, `spec.json`, `spec.resolved.json`,
`spawn-plan.txt`, `launch.json`, `launch.err`, `preflight.json`, `log/run.log`, `out/` (what the
spec pushed, plus `requests.tsv`), `spawn/<task_id>/{completion.json,command.log,.exitcode}`,
`completion.json`, `tables/phases.tsv`, `tables/requests.tsv`, plus `decoded/` and `tables/` from
a post script. In S3, the same tree is under
`s3://cookbook-942542972736-us-west-2/aws-kraken2/<gate>/<run-id>/`.

Exit status: the task's exit code, or one of these harness codes:

| code | meaning |
|---|---|
| 2 | spec refused, launch failed, or launched in the wrong region (instance terminated) |
| 3 | orphans found, or a region could not be checked |
| 4 | a manifest update failed |
| 95 | `ak2_drop_caches` could not drop caches (a cold rung was impossible) |
| 96 | the body exited 0 but an `ak2_req` call was invalid |
| 97 | the on-instance region or Payer assert failed, or the log tee/mkfifo/shim could not start |
| 129 / 130 / 143 | the body was killed by HUP / INT / TERM (the log still reached S3) |
| 98 | the post script failed |
| 99 | no completion record |
| 126 | (in the log) an `aws` call was refused by the allow-list |

## Failure looks like

- `make run: …` followed by exit 2, before launch: the spec was refused, and the message names
  the rule. Nothing was launched.
- `FATAL: …` in `log/run.log`, exit 97: cross-region placement, or a Requester-pays bucket
  without opt-in. Caught before the spec body ran.
- `ak2: REFUSED aws … undeclared bucket(s)` in the log: declare the bucket in `AK2_DATASETS`.
- Exit 95 with `FATAL: drop_caches …`: the instance could not drop caches, so the run stopped
  before a rung it would have reported as cold. `tables/phases.tsv` shows which phases were cold.
- `no completion record by TTL+3m`: the TTL or cost limit killed the task. `log/run.log` and
  `spawn/<task_id>/command.log` (from spored's pre-stop flush) show how far it got. Raise the TTL
  only after reading them.
- `manifest.json` without `manifest_finalised_at`: run.sh was interrupted. Run `make orphans` now.
- `ORPHANS FOUND`, exit 3: see [orphans.md](orphans.md).

**Never rewrite cited history.** `manifest.json` records the launch commit, so do not squash or
rebase commits that a run under `results/` cites. Merge them as they are.
