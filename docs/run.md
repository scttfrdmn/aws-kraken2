# make run GATE=… SPEC=…

**What:** launches one checked-in TaskSpec from `runs/` through `spawn task run`. It enforces
Law 4 so that no spec can skip it, records `results/<gate>/<run-id>/`, and checks that its own instance is gone (`scripts/orphans.sh --own`)
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
    (8 h). `lifecycle.cost_limit` must be positive and at most `AK2_MAX_COST_USD` ($50, a hard
    backstop; $5 per run is Scott's guide, not a cap). Both ceilings are in `ak2.env`. Set each
    spec's `cost_limit` to what that run needs. `on_complete` is forced to `terminate`;
  - `command` is `["bash","-c","<script>"]`. `container`, `inputs[]` and `results_prefix` are
    refused: spawn would stage inputs before the preamble's region assert, so use `ak2_stage`;
  - the script may not turn errexit back on; Law 4 says `set +e`. See [errexit](#errexit) below;
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
  and records the commit it ran at. Its one permitted write to `manifest.json` is adding a
  **verified digest** to an existing `datasets[]` entry: `sha256`, `sha256_source` (the run-dir
  file it came from) and `sha256_check` (the checks it passed, e.g. the ETag held for the whole
  read). Nothing else in the manifest may change (`scripts/post/g0c-runs.sh` is the one user).

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
| `ak2_phase NAME` | marks the start of a phase; `run.sh` derives `tables/phases.tsv` (phase, start, seconds, cold) and `manifest.phases`. A phase still running when the run was killed hard has empty seconds (`null`). NAME must be a non-empty word |
| `ak2_req OP N [BUCKET]` | records N S3 requests of type OP in the current phase; becomes `out/requests.tsv`, `tables/requests.tsv` and `manifest.requests`. OP must be a non-empty word, N a non-negative integer, and BUCKET empty or a valid bucket name (no tabs or newlines) |
| `ak2_stage SRC DST` | stage an input from a declared bucket (signed, then anonymous); `SRC` ending in `/` is recursive |
| `ak2_push FILE [NAME]` | stream a result to `<run prefix>/out/NAME` now |
| `ak2_drop_caches` | required before every cold rung. Marks the **next** `ak2_phase` as `cold=yes`. If the preflight found `drop_caches_ok=false`, or the drop fails, it ends the run with exit 95; a warm rung is never mislabelled cold |

The helpers are `readonly -f`. The body must not replace the EXIT/TERM/HUP/INT/PIPE traps.
- **Errors count from anywhere.** A helper error (bad `ak2_req`/`ak2_phase` arguments, a
  `drop_caches` failure, a fatal assert) is appended to `/tmp/ak2-state/errors`, a file rather
  than a variable. Errors from helpers called in subshells therefore still count. If the body
  would have exited 0, the run instead exits with the first error's code (96, or 95 for
  `drop_caches`), and the file is pushed as `out/helper-errors.tsv`.
- **State the body can't clobber.** The current phase, the cold marker and the finish lock are
  files under `/tmp/ak2-state`. The lock is an atomic `mkdir`, taken only by the main shell
  (checked against `$BASHPID`). So neither a subshell calling `ak2_finish` nor a variable
  assignment can make the real finish skip.
- **Exits under signals.** On any exit, including a process-group SIGTERM at shutdown, the
  finish handler logs the real status and pushes `run.log` and `requests.tsv`. The statuses are
  143 for TERM, 129 for HUP, 130 for INT and 141 for PIPE (e.g. the tee died). The handler writes
  straight to the log file, so it cannot itself SIGPIPE.
- **Tee startup.** The tee ignores TERM/HUP. The preamble checks it started within 5 s; if not,
  it KILLs it and exits 97.
- **Shim checks.** The shim must be non-empty and executable, and its `cksum` must match what
  was written. It must also refuse an undeclared bucket in a self-test; otherwise exit 97.
- **`wait`.** A bare `wait` is safe, because the tee and the pusher are disowned.

### errexit

Law 4 says `set +e`, enforced in two layers.

**Statically**, `run.sh` runs `scripts/lib/errexit_check.py` over the script. `make test` runs
its self-test cases. It tokenises like a shell, so quotes, backslashes, comments, heredoc bodies
and separators are understood, and it inspects every simple command's option words:
- `set`: any option cluster containing `e`, or `-o errexit`, before `--` or the first positional
  word. This catches `set -e`, `set -u -e`, `set -euo pipefail`, `set -o pipefail -e` and
  `set -o nounset -o errexit`.
- `shopt`: `-s` and `-o` in any spelling, with `errexit`.
- `bash`/`sh`/`dash`/`ksh`/`zsh`: an `e` option cluster or `-o errexit`. The `-c` string is
  re-checked.
- `eval`: its arguments are re-checked, so `eval "set -e"` is caught.
- A `-e` shebang.

Before reading the command name, the checker skips assignments and keywords. It also skips the
wrappers `exec`, `env` (options and `VAR=val` words), `sudo` (options), `timeout [opts] N`,
`nohup`, `nice [-n N]`, `xargs [opts]`, `stdbuf [opts]` and `command`. So `sudo -u x bash -e` and
`timeout 5 sh -e` are both caught. Arithmetic (`$((a << 2))`, `((x <<= 1))`) is data, not a
heredoc. If the checker itself throws, it exits 2, and `run.sh` reports "errexit check crashed"
instead of passing or failing the spec.

Quoted text and heredoc bodies are data, so `echo "set -e"` is allowed. Static parsing does not
see:
- code inside `"$( … )"` within double quotes;
- commands reached through variables (`$cmd -e`), aliases, or computed `eval` strings;
- `source`d files.

**At run time**, the preamble asserts at body start that `$-` lacks `e` (fatal, exit 97).
`ak2_finish` checks again at exit; if `e` is on, it logs it, and a run that would have exited 0
exits 96.

Every spec must count its requests with `ak2_req`; `run.sh` warns if none were recorded.

## User data: the stub and the payload

EC2 caps user data at **16384 bytes after base64 decoding**. spawn (0.121.0 and 0.123.0) sends
`base64(gzip(bootstrap))`, where the bootstrap embeds the task wrapper, which embeds
`command[2]`. spawn's own bootstrap already takes about 10.4 KB of the gzip budget. Inlining the
preamble and the spec body overran it: g1 measured 17781 bytes and failed at RunInstances, and
g0a measured 15211 bytes and passed. Precompressing the inline text does not help, because spawn
gzips it again; it measured 1–1.5 KB *worse*.

So `command[2]` is `scripts/stub.sh`, about 1.9 KB, and the **payload** (`scripts/preamble.sh` +
`\n` + the spec body, byte for byte what used to be inlined) goes to `<run prefix>/payload.sh`.
- `run.sh` uploads the payload before launch and checks the uploaded sha256.
- It passes the stub `AK2_PAYLOAD_URI`, `AK2_PAYLOAD_SHA256`, and `AK2_PAYLOAD_URL`, a presigned
  GET for that one object valid for TTL + 1 h. The instance needs no extra IAM grant on the
  shared bucket.
- The URL-bearing spec that spawn reads is a `mktemp` file outside `results/`, removed by an
  EXIT trap. `spec.resolved.json` under `results/` is only ever written with the URL redacted.
- The stub checks that the URL is `https://<bucket>.s3.<region>.amazonaws.com/…` for the
  asserted region, and unsets it before exec.
- The payload must be under 120 KiB, because it travels as one `bash -c` argument (Linux caps
  a single argument at 128 KiB).

The stub keeps Law 4's order:
1. It records `$-` first, then runs `set +e`.
2. It does the IMDSv2 region assert, plus the payload bucket's region, before any I/O (exit 97).
3. It makes one curl GET, checks the sha256 (exit 97 on mismatch), and runs
   `exec bash -c "<payload>"`, the same parsing and `$-` semantics as the inline script.
4. The preamble then runs unchanged. It logs both its own `$-` and the stub's, and
   `preflight.inherited_flags` is the stub's, i.e. what spawn started.

A stub failure appears in `spawn/<task_id>/command.log`, because the preamble's log streaming
has not started yet.

**Size check.** Before the plan, and so in `DRY_RUN=1` too, `run.sh` builds `scripts/udsize`. This
is a separate Go module that links the pinned spawn version's own `taskproto.GenerateWrapper`,
`GenerateFlushScript`, `launcher.BuildLinuxBootstrap` and `EncodeLinuxUserData`. It measures the
exact user data for the resolved spec. `run.sh` refuses to run at all if `spawn version` differs
from the spawn version pinned in `scripts/udsize/go.mod` (bump it there and `go mod tidy`). It
refuses if the result exceeds
16384 − `AK2_USERDATA_MARGIN` (1024, in `ak2.env`). The manifest records `user_data` and
`payload` (URI, sha256, bytes).

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
5. Tails `<run prefix>/log/run.log` every 15 s until one of these happens:
   - `completion.json` appears;
   - the instance terminates, or EC2 no longer describes it (it has aged out);
   - TTL + 3 min passes **while S3 answers that the record is absent**.

   Every AWS call from the launch describe on has connect and read timeouts (`aws_try`). The
   call either returns, is authoritatively absent, or failed.
   - **Absent** is decided per service. For s3 it is NoSuchKey, 404 or Not Found. For ec2 it is
     only `InvalidInstanceID.NotFound`, or a `--query` that prints `None`.
   - **Failed** covers everything else, including a generic ec2 404. A failed call is logged
     with its reason, at most once a minute, and the poll backs off from 15 s up to 120 s.

   `instance.final_state_basis` records how the final state was decided: `observed`
   (DescribeInstances said so), `aged_out` (EC2 no longer knows the instance), or `unknown`.
   The end-of-run describe overrides an earlier inference: whatever state EC2 answers becomes
   `final_state`, with basis `observed`. `scripts/refinalise.sh` treats a `final_state` whose
   basis is `unknown` as unset. Each attempt is a fresh process, so DNS is re-resolved. If calls are
   failing, the poll keeps going for up to `AK2_POLL_GRACE_S` (6 h) past TTL + 3 min. This
   matters because the record may already be in S3: on 2026-10-07, a launch-host network outage
   made three drivers give up at TTL + 3 min and spin in the termination wait. It then waits for
   `terminated` (extending while calls fail) and copies the run prefix into the run dir, with 5
   tries.
6. Derives `tables/phases.tsv` and `tables/requests.tsv`, then finalises the manifest with the
   completion record, preflight, phases, requests, stop time (from `StateTransitionReason`),
   billed seconds and `cost_usd`. `cost_usd` is the truffle price × (terminate − launch) with a
   60 s minimum: compute only, an estimate rather than a bill. If any manifest update fails after
   launch, the run continues and exits 4.
7. Runs `scripts/post/<name>.sh` if present, then the scoped `scripts/orphans.sh --own <task_id> <instance_id>`: it fails only if this run's instance survives; concurrent runs' instances are listed for information. `make orphans` stays global and strict.

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
`completion.json`, `orphans.txt` (the post-run orphan check), `tables/phases.tsv`, `tables/requests.tsv`, plus `decoded/` and `tables/` from
a post script. In S3, the same tree is under
`s3://cookbook-942542972736-us-west-2/aws-kraken2/<gate>/<run-id>/`.

Exit status: the task's exit code, or one of these harness codes:

| code | meaning |
|---|---|
| 2 | spec refused, launch failed, or launched in the wrong region (instance terminated) |
| 3 | this run's own instance is still alive after the run, or a region could not be checked (other live ak2 instances are listed, not counted) |
| 4 | a manifest update failed |
| 95 | `ak2_drop_caches` could not drop caches (a cold rung was impossible) |
| 96 | the body exited 0 but a helper call was invalid, or errexit was on at exit |
| 97 | the on-instance region or Payer assert failed; the log tee, mkfifo or shim could not start or verify; or errexit was on at body start |
| 129 / 130 / 141 / 143 | the body was killed by HUP / INT / PIPE / TERM (the log still reached S3) |
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
- `manifest.json` without `manifest_finalised_at`: run.sh was interrupted, or its finalisation
  failed. Run `make orphans` now. If the instance fields are null (DescribeInstances answered
  `InvalidInstanceID.NotFound` right after launch; run.sh now retries for 2 minutes), run
  `scripts/refinalise.sh results/<gate>/<run-id>`. Run it the same way when the driver died or
  its fetch failed. It:
  - fetches and tags the run prefix;
  - derives `tables/`;
  - fills only unset fields (null or `""`), from DescribeInstances while EC2 still describes
    the instance (about an hour after termination);
  - applies run.sh's finalisation;
  - runs the scoped orphan check and records `.orphan_check` when the manifest has none;
  - writes one repair record, with its gaps, `stop_basis` and object-tag result, to
    `.manifest_repair`.

  If the instance has aged out:
  - `final_state` is `terminated`, with `final_state_basis` `aged_out`;
  - `stop` is the completion record's `ended_at` (`stop_basis` says so);
  - `cost_basis` says the cost undercounts the shutdown.

  A generic describe error leaves the instance fields alone and is listed as a gap. The script
  refuses a manifest that already has `.manifest_repair`, or that is finalised with its
  completion record. `--force` appends a further repair to `.manifest_repairs[]` and never
  overwrites set fields. `make test` runs `scripts/lib/harness_poll_test.sh` against a stubbed
  `aws`.
- `THIS RUN'S INSTANCE IS STILL ALIVE`, exit 3: see [orphans.md](orphans.md).

**Never rewrite cited history.** `manifest.json` records the launch commit, so do not squash or
rebase commits that a run under `results/` cites. Merge them as they are.
