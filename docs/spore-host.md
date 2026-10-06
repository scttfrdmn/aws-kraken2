# spore.host in this repo

How aws-kraken2 uses spawn, truffle, lagotto, spored and cohort. Verified against spawn 0.121.0, re-checked for 0.123.0
(source: `spore-host/spawn` tag `v0.121.0`, `pkg/taskproto/`, `cmd/task.go`,
`pkg/launcher/bootstrap.go`) and truffle 0.57.1. Every AWS run goes through `make run`
([run.md](run.md)), never through raw `spawn launch`.

## The tools

| tool | where | what we use it for |
|---|---|---|
| `spawn` | `/opt/homebrew/bin/spawn` (brew `spore-host/tap/spawn`) | `spawn task run --spec` launches one ephemeral instance per TaskSpec |
| `spored` | installed on the instance by spawn's bootstrap; not a local CLI | enforces TTL, `cost_limit` and `on_complete`; runs the pre-stop flush hook |
| `truffle` | `/opt/homebrew/bin/truffle` | sizing inside spawn; `truffle find <type> --regions R --show-price -o json` for the price recorded in the manifest |
| `lagotto` | `/opt/homebrew/bin/lagotto` | capacity watches for scarce types. Not needed so far |
| `cohort` | Go library `github.com/spore-host/cohort`, no CLI | all-or-nothing multi-node sets. Not used yet; if a sharded run needs it, it is imported, not installed |
| nf-spawn | Nextflow plugin | not used; its orphan bug (nf-spawn#96) is why `make orphans` runs after every run |

## The TaskSpec

Parsing is strict (`DisallowUnknownFields`): an unknown key is a parse error. Our own
metadata therefore lives in `env`, not in extra top-level keys. The fields we use:

| field | meaning |
|---|---|
| `task_id` | set by `run.sh` to `ak2-<gate>-<run-id>`; spawn tags it as `spawn:task-id` and `Name` |
| `command` | must be `["bash","-c","<script>"]`; `run.sh` prepends `scripts/preamble.sh` to the script |
| `resources.{cpu,memory_gib,architecture,families}` | sizing; spawn picks the cheapest fitting type via truffle. `instance_type` pins one exactly |
| `resources.disk_gib` | root EBS size. `/tmp` on AL2023 is a tmpfs of about half RAM, *not* this disk |
| `inputs[]` | **refused by `run.sh`**: spawn stages them before the preamble's region assert. Use `ak2_stage` |
| `outputs[]` | `aws s3 cp` after the command; destinations must start with `${AK2_OUT}/` |
| `resources.s3_read_write` | spawn's full read-write IAM grant; only for declared private buckets `ak2_stage` must read |
| `lifecycle.ttl` | hard deadline (Go duration). Required by spawn and by `run.sh` |
| `lifecycle.cost_limit` | USD of compute; spored terminates when reached. Optional in spawn, required by `run.sh` |
| `lifecycle.on_complete` | `run.sh` forces `terminate` |
| `results_prefix` | set by `run.sh` to `<run prefix>/spawn`; spawn writes `<task_id>/{completion.json,.exitcode,command.log}` there. It must be an existing bucket |
| `env` | exported in the wrapper before the command. Our keys: `AK2_REGION`, `AK2_ACCESSIONS`, `AK2_DATASETS` (the bucket allow-list), opt-ins `AK2_ALLOW_NO_BUCKETS` and `AK2_ALLOW_REQUESTER_PAYS`, and optional `BUCKET_REGION`. `run.sh` adds `AK2_EXPECT_REGION`, `AK2_BUCKETS`, `AK2_ALLOWED_BUCKETS`, `AK2_S3_PREFIX`, `AK2_RUN_ID` and `AK2_GATE`, and refuses specs that set them or `BASH_ENV`/`ENV` |

`container` is rejected by `run.sh`, because spawn runs the container command directly and the
preamble could not run first. To use an aarch.bio image, `docker run` it, pinned by digest,
from the host script. spawn then plays no part in the container's uid or mounts, so give
output dirs `chmod 1777`.

## What happens on the instance

1. Bootstrap writes `/tmp/spawn-command.sh` as `#!/bin/bash` + `set -e` + the wrapper. The wrapper
   immediately runs `set +e -u -o pipefail` (that is spawn#707's `bash -e`; the preamble echoes
   `$-` so the log always shows what was in force).
2. Wrapper: exports `env`, stages inputs, runs `( bash -c <preamble+script> )` as the instance
   user via `su -`, stages outputs, uploads `/var/log/spawn-command.log` to
   `<results_prefix>/<task_id>/command.log`, writes `completion.json` and `.exitcode`, then
   writes `/tmp/SPAWN_COMPLETE`.
3. spored sees `/tmp/SPAWN_COMPLETE` and terminates after about 10 s (`on_complete: terminate`).
4. On a TTL or cost-limit kill, spored first runs `/etc/spawn/task-flush.sh` (spawn#632/#643: the
   pre-stop flush exists for `task run` only, not `spawn launch --command`). That uploads
   `command.log` and a failed completion record.

The instance role is scoped to `s3_read_write` buckets (we use no `inputs[]`) and `PutObject` on `outputs[]` and the
results bucket. Nothing else is granted, so a public bucket that is not an input, such as RODA,
must be read with `--no-sign-request`. `get-bucket-request-payment` on our own bucket fails from
the instance; the preamble falls back to an anonymous call, then records `UNKNOWN`, and the
launch host records the Payer too.

## How logs and outputs leave the instance

- The preamble `tee`s all output to `/tmp/ak2-run.log` through a FIFO; the tee and the pusher
  are disowned, so a bare `wait` in a spec doesn't hang. A background loop pushes the log every 5 s to
  `<run prefix>/log/run.log`, with a final push from the EXIT trap. This is independent of spawn's
  end-of-run `command.log`.
- `ak2_push FILE` streams a result to `<run prefix>/out/` as soon as it exists, so a TTL kill loses
  at most the step in flight.
- `<run prefix>` is `s3://cookbook-942542972736-us-west-2/aws-kraken2/<gate>/<run-id>`. After the
  run, `run.sh` copies the whole prefix into `results/<gate>/<run-id>/`.

## Results bucket

We reuse the cookbook's `COOKBOOK_BUCKET` (`cookbook-942542972736-us-west-2`, us-west-2,
`Payer: BucketOwner`) under the prefix `aws-kraken2/`, rather than creating
`aws-kraken2-<account>-<region>`. It has no lifecycle rule, and we did not add one: the bucket is
shared, and the durable copy of every run is the checked-in `results/` tree. If the prefix grows,
deleting `aws-kraken2/` is safe. Runs in another region need their own in-region bucket, named in
`scripts/ak2.env` as `AK2_RESULTS_BUCKET_<region>`; until then `run.sh` refuses that region.

## Tagging and finding instances

- spawn tags `spawn:task-id=ak2-…`, `Name=ak2-…`, plus its own `spawn:ttl`, `spawn:price-per-hour`,
  and so on. `task run` has no field for custom tags.
- `run.sh` adds `ak2:project=aws-kraken2`, `ak2:gate`, `ak2:run-id` with `aws ec2 create-tags`
  right after launch.
- `make orphans` matches either selector in every region enabled in the account.
  `spawn list --tag spawn:task-id=…` works too, but only for exact values.

## Regions

Launch region = `env.AK2_REGION`, passed as `spawn task run --region`. Before launch, `run.sh`
refuses unless every bucket in `AK2_DATASETS` reports that region (from the
`x-amz-bucket-region` header) and the results bucket is in it too. On the instance, the preamble
re-checks the IMDSv2 region against the same buckets before any data I/O and exits 97 on a
mismatch. A cross-region placement is silent otherwise, and `InvalidInstanceID.NotFound` usually
means wrong region.

## Known traps

| issue | trap | what we do |
|---|---|---|
| spawn#707 | `--command` runs under inherited `bash -e`; `set -uo pipefail` does not clear it | preamble does `set +e` and logs `$-` before and after |
| spawn#643 / #632 | pre-stop log flush only for `task run` | we only use `task run`; plus our own 5 s log push |
| spawn#555 / #565 | container uid vs staged-file ownership (older: flat `/tmp`, `EPERM` on `rm`) | no `container`; never `rm` a staged input; `chmod 1777` output dirs for `docker run` |
| spawn#564 | directory outputs on the container path were unwritable | tar directories, or `ak2_push` files |
| spawn#579 | no snapshot-based data path yet | stage from S3 or stream; no EBS snapshots |
| nf-spawn#96 | orphaned instances after a workflow | `make orphans` after every run (`run.sh` calls it) |
| strict parse | unknown TaskSpec key fails validation | metadata in `env` |
| IAM scope | instance can read only `inputs[]`/`s3_read_write` buckets | `--no-sign-request` for public data; `ak2_stage` tries signed, then anonymous |
| allow-list scope | the preamble's `aws` PATH shim sees only the `aws` CLI found via `PATH` | curl/SDK/`sudo aws` are not covered; keep data I/O on the CLI |
| launch region | spawn could place the task elsewhere | `run.sh` terminates and fails if `launch.json` region != `AK2_REGION` |
| tmpfs | `/tmp` is about RAM/2 whatever `disk_gib` says | size `memory_gib` or stage to a non-`/tmp` path |
| user-data cap | 16384 bytes after base64 decoding; spawn gzips its bootstrap and uses about 10.4 KB itself | `command[2]` is `scripts/stub.sh`; preamble and body travel as a sha256-checked payload via a presigned URL; `run.sh` measures with spawn's own builders (`scripts/udsize`) |
| 0.123.0 changes | `spawn-command.sh` now prints `$-` and an errexit warning (#707); `task status`/`--wait` read completion records again (#715: v0.117.0–v0.121.0 looked under `<task_id>/<task_id>/`). Wrapper, flush hook and `Provision` are unchanged | `run.sh` polls `<results_prefix>/<task_id>/completion.json` itself, so #715 never affected it; `scripts/udsize` is pinned to v0.123.0 and `run.sh` refuses a mismatched `spawn version` |
| slow sizing | `task run` sizing (truffle search + live price per candidate) took ~4 min per call in 0.121.0 | `run.sh` sizes once (`--dry-run`) and pins `instance_type` for the launch |
| local Docker | macOS lies about sticky bits, cgroup memory and CPU features | the AWS run is the only verdict |
