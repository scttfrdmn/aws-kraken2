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
- `SPEC`: `runs/<name>.json`. It must be committed with no local changes, because the manifest
  cites its commit and sha256. It is a normal spawn TaskSpec with these constraints:
  - `lifecycle.ttl` and a positive `lifecycle.cost_limit` are required; `on_complete` is forced
    to `terminate`;
  - `command` is `["bash","-c","<script>"]`. `container` and `results_prefix` are refused;
  - `env.AK2_REGION`: the launch region;
  - `env.AK2_ACCESSIONS`: space-separated sample accessions (`""` for none). The key must be present;
  - `env.AK2_DATASETS`: space-separated `s3://` object URIs whose ETag and VersionId go into the
    manifest and whose buckets are region- and Payer-checked;
  - `env.BUCKET_REGION` (optional): declare the bucket region explicitly; it must still match;
  - `outputs[].destination` may use `${AK2_OUT}`, which becomes `<run prefix>/out`.
- Optional `scripts/post/<name>.sh` (same basename as the spec): run locally after fetch as
  `scripts/post/<name>.sh <run-dir>`. It may read only the run dir and write `decoded/` and
  `tables/` there, and can be re-run on an existing run dir (it records the commit it ran at).
- The spec body may use `ak2_say MSG`, `ak2_push FILE [NAME]` (stream a result now) and
  `ak2_drop_caches` (required before every cold rung), plus `$AK2_REGION` and `$AK2_S3_PREFIX`.
  It must not replace the EXIT trap.

## What it does

1. Validates the spec. For every bucket in `inputs[]` and `AK2_DATASETS`, it looks up the region
   (`x-amz-bucket-region`) and refuses if any differs from `AK2_REGION` or from the results
   bucket's region.
2. Picks `RUN_ID=<UTC yyyymmdd-hhmmss>-<short sha>` and `task_id=ak2-<gate>-<run-id>`, and writes
   `spec.json` (the original) and `spec.resolved.json` (preamble prepended, harness env added).
3. Writes `manifest.json` with: commit (and dirty flag), upstream pin, spec sha256, tool versions,
   TTL and cost limit, accessions, head-object of each dataset (ETag, VersionId, size), and the
   Payer of each bucket.
4. Runs `spawn task run --dry-run` (saved as `spawn-plan.txt`) and pins the planned type into
   `spec.resolved.json` as `resources.instance_type`. spawn sizing takes about 4 minutes per
   call, and the launch must be the box the plan priced. It then launches with `-o json`
   (`launch.json`), tags the instance `ak2:project/gate/run-id`, and adds instance type and
   count, AMI, AZ, launch time and the truffle on-demand price to the manifest.
5. Tails `<run prefix>/log/run.log` every 15 s until `completion.json` appears, the instance
   terminates, or TTL + 3 min passes. It then waits for `terminated` and copies the whole run
   prefix into the run dir.
6. Finalises the manifest with the completion record, the instance preflight, stop time
   (from `StateTransitionReason`), billed seconds and `cost_usd`. `cost_usd` is the truffle
   price × (terminate − launch) with a 60 s minimum: compute only, an estimate rather than a bill.
7. Runs `scripts/post/<name>.sh` if present, then `scripts/orphans.sh`.

On the instance, `preamble.sh` runs first: `$-` before and after `set +e`, IMDSv2
region/AZ/type/AMI, the region assert against every bucket, the Payer of each bucket,
`preflight.json`, and then the background log push every 5 s plus a final push on exit.

## Outputs

`results/<gate>/<run-id>/`: `manifest.json`, `spec.json`, `spec.resolved.json`,
`spawn-plan.txt`, `launch.json`, `launch.err`, `preflight.json`, `log/run.log`, `out/` (whatever
the spec pushed), `spawn/<task_id>/{completion.json,command.log,.exitcode}`, `completion.json`,
plus `decoded/` and `tables/` from a post script. In S3, the same tree is under
`s3://cookbook-942542972736-us-west-2/aws-kraken2/<gate>/<run-id>/`.

Exit status: the task's exit code. 2 means the spec was refused or the launch failed; 3 means
orphans were found; 97 is the task exit when the on-instance region assert failed; 98 means the
post script failed; 99 means there is no completion record.

## Failure looks like

- `make run: …` followed by exit 2, before launch: the spec was refused (missing TTL or
  cost_limit, uncommitted spec, a region mismatch, no results bucket for the region). Nothing
  was launched.
- `FATAL: instance region … != expected …` in `log/run.log`, exit 97: cross-region placement,
  caught before any data I/O.
- `no completion record by TTL+3m`: the TTL or cost limit killed the task. `log/run.log` and
  `spawn/<task_id>/command.log` (from spored's pre-stop flush) show how far it got. Raise the TTL
  only after reading them.
- `manifest.json` without `manifest_finalised_at`: run.sh was interrupted. Run `make orphans` now.
- `ORPHANS FOUND`, exit 3: see [orphans.md](orphans.md).

**Never rewrite cited history.** `manifest.json` records the launch commit, so do not squash or
rebase commits that a run under `results/` cites. Merge them as they are.
