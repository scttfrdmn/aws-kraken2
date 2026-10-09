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
    (8 h). `lifecycle.cost_limit` must be positive and at most `AK2_MAX_COST_USD` ($500). That
    ceiling is a sanity check against typos, not a budget: Scott ruled on 2026-10-09 (#25) that
    there is no budget envelope or spend cap, and spend is tracked only (manifest `cost_usd`,
    `results/g3/campaign/spend.tsv`). Both ceilings are in `ak2.env`. Each spec's TTL and
    `cost_limit` are its runaway backstops. Set `cost_limit` to TTL × the on-demand price, as
    `scripts/g3/mkspec.sh` does. `on_complete` is forced to `terminate`;
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
  - `env.AK2_ACCESSIONS`: space-separated sample accessions (`""` for none), or a reference to a
    recorded cohort range, `@<project>:<a>-<b>` (see [Sample accessions](#sample-accessions)).
    The key must be present;
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

## Sample accessions

`env.AK2_ACCESSIONS` is either a literal space-separated list or a **reference** to a recorded
cohort range:

```
"AK2_ACCESSIONS": "@PRJNA398089:1-1000"    # ranks 1..1000 of results/cohort/PRJNA398089/runs.tsv
```

The spec env travels in the EC2 user data, which has no room for long lists: c1000's 1000
accessions are 1792 B gzipped, against about 1000 B of headroom. A reference is 20 B.

- **Resolution.** `scripts/lib/accessions.sh [-r REPO_ROOT] VALUE` prints the accessions,
  space-separated. A reference names ranks a..b (inclusive, 1-based; column 1 of runs.tsv is
  `rank`, column 2 `run`). Each rank must be present exactly once and in order, and every
  accession must look like one (`^[A-Z]+[0-9]+$`). Anything else exits 2 with the reason. A
  literal list is printed back with its whitespace normalised.
- **On the launch host.** `run.sh` expands the value into `manifest.sample_accessions` (the full
  list, as before) and records `manifest.sample_accessions_ref = {ref, runs_tsv, blob}`, where
  `blob` is the git blob id of runs.tsv at the run's commit. It refuses a reference whose
  runs.tsv is not committed or has local changes, because the node reads the committed file.
  `run-multi.sh` resolves the reference once before any launch (fail fast) and records it in
  `cohort.json` as `sample_accessions_ref`. Only the reference goes into the spec env, and so into
  user data.
- **On the node.** The body resolves the same value from its repo checkout at the run's commit
  (the bodies clone the repo and check out the commit from the cohort id or run id):

  ```bash
  ACC=$("$W/repo/scripts/lib/accessions.sh" -r "$W/repo" "$AK2_ACCESSIONS")
  ```

  `scripts/g3/campaign.body.sh` does this and fails unless the list equals the first `COHORT`
  runs it reads from the same runs.tsv. `make rehearse` passes the spec's `AK2_ACCESSIONS` to the
  rehearsal nodes, so the rehearsal exercises the same resolution.
- `scripts/g3/mkspec.sh` writes `@PRJNA398089:1-<COHORT>`. Specs generated before this change
  carry the literal list; they still work unchanged.

## vCPU quota

Every launch path checks the region's on-demand vCPU quota before anything is sent, with
`scripts/lib/quota_check.sh REGION TYPE COUNT`:

1. The type maps to its on-demand quota family by the letters before its first digit:
   - Standard (A, C, D, H, I, M, R, T, Z; also `im`, `is`): `L-1216C47A`;
   - X: `L-7295265B`;
   - High Memory (`u`): `L-43DA4232`;
   - F: `L-74FC7D96`; G and VT (`g`, `gr`, `vt`): `L-DB2E81BA`; P: `L-417A185B`;
   - Inf: `L-1945791B`; Trn: `L-2C3B7624`; DL: `L-6E869C2A`; HPC: `L-F7808C92`.

   A type with no known family (for example `mac2.metal`) is refused; add its prefix to
   `family_of` in the script.
2. Requested = COUNT × the type's default vCPUs (`describe-instance-types`).
3. Running = the default vCPUs of every on-demand instance of the same family in the region in
   state pending, running, stopping or shutting-down, of any project (the quota is per account and
   region). Spot and capacity-block instances have their own quotas and are not counted.
4. The sum is compared with the family's applied quota (`service-quotas get-service-quota`). Over
   it: exit 1, with the requested, running and quota vCPUs in the message. A failed or
   unparsable call: exit 2. Both refuse the launch.

Only read-only calls are made, under `AWS_PROFILE` (`aws`, from `ak2.env`). The record (one JSON
object) goes into `manifest.quota_check` (run.sh) and `cohort.json`'s `quota_check` (run-multi.sh).

- `run-multi.sh` checks all NODES members at once, before the network check and before
  `DRY_RUN` stops.
- `run.sh` checks one instance of the planned type, after the spawn plan and before `DRY_RUN`
  stops. For a cohort member that counts the members already up, so it still holds if a
  member is relaunched by hand.

For example, us-west-2's X quota is 128 vCPU: one x8g.24xlarge (96) is allowed, two (192) are
refused, and one is refused while another X instance of 48 vCPU or more is running.
`scripts/lib/quota_check_test.sh` (in `make test`) checks this against a stubbed `aws`;
`scripts/lib/run_multi_test.sh` checks that run-multi.sh refuses 2 × x8g.24xlarge before any
launch, under `DRY_RUN=1` too.

## DRY_RUN of every spec

```bash
make dryrun-userdata                                          # every committed runs/*.json
make dryrun-userdata GEN="c1000 x8g.24xlarge 1 1000"          # plus generated campaign specs
make dryrun-userdata GEN="c1000 x8g.24xlarge 1 1000; c1000 c8g.12xlarge 32 1000"
```

`scripts/dryrun-userdata.sh` runs `DRY_RUN=1` of every spec through the driver a launch would
use: `run-multi.sh` with n = the body's `WANT_N` (else 1) when the spec pins the type and the AZ,
and `run.sh` otherwise. The gate is the spec name's `g<digit>[a-z]` prefix (loadbench: `g2`, else
`g3`), because the task id and prefixes are part of the user data. Each `GEN` entry is
`scripts/g3/mkspec.sh`'s arguments. The generated spec is committed in a scratch git worktree of
HEAD under `$TMPDIR` (a detached commit that is never pushed; the record's `scratch_commit`), dry-run from
there and copied beside the record. The worktree is then removed.

The record is `results/rehearse/dryrun-userdata-<UTC>-<sha7>.tsv`, with columns `spec`,
`driver`, `rc`, `gzip_bytes`, `limit` (16384 − `AK2_USERDATA_MARGIN`), `headroom`, `quota`
(`ok|REFUSED <n>x<type> <total>/<quota> <code>`), `scratch_commit` and `note`. The target exits
non-zero if any spec is refused or over the limit. It launches nothing; the AWS calls it makes
are the pre-launch checks', spawn's `--dry-run` plan and the quota check's.

## User data: the stub and the payload

EC2 caps user data at **16384 bytes after base64 decoding**. spawn (0.121.0 and 0.123.0) sends
`base64(gzip(bootstrap))`, where the bootstrap embeds the task wrapper, which embeds
`command[2]`. spawn's own bootstrap already takes about 10.4 KB of the gzip budget. Inlining the
preamble and the spec body overran it: g1 measured 17781 bytes and failed at RunInstances, and
g0a measured 15211 bytes and passed. Precompressing the inline text does not help, because spawn
gzips it again; it measured 1–1.5 KB *worse*.

So `command[2]` is `scripts/stub.sh` with the utilisation sampler spliced in
(`scripts/lib/mkstub.sh`; kept as the run dir's `stub.sh`), and the **payload** (`scripts/preamble.sh` +
`\n` + the spec body, byte for byte what used to be inlined) goes to `<run prefix>/payload.sh`.
- `run.sh` uploads the payload before launch and checks the uploaded sha256.
- It passes the stub `AK2_PAYLOAD_URI`, `AK2_PAYLOAD_SHA256`, and `AK2_PAYLOAD_URL`, a presigned
  GET for that one object valid for TTL + 1 h. The instance needs no extra IAM grant on the
  results bucket.
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

## Utilisation

Every run on both arms records how much of the machine it used over the **billed window**,
which is `launch_time` → `terminated_at` per node; a fleet sums node-seconds. This is Scott's
definition on #25 (2026-10-09). The three utilisations are reported separately and never
combined. Each gets its own effective cost, billed $ ÷ U_r.

- **U_cpu** = busy vCPU-s ÷ (vCPUs × billed s).
  - busy = user + nice + system + irq + softirq + steal, from `/proc/stat`. guest is already
    inside user; idle and iowait count as idle. Sys time counts as used.
  - `/proc/stat` integrates from boot, so CPU between `btime` and the first tick is counted.
- **U_mem** = time-mean (MemTotal − MemAvailable) ÷ installed memory (`MemoryInfo.SizeInMiB`).
  - The peak (the largest 1 Hz sample) is reported beside it.
  - Shmem/tmpfs counts as used.
  - Memory is a gauge, so it is integrated only over tick intervals no longer than 2.5 × the
    sampling period. A longer interval is a gap: it counts as 0, and `mem_gap_s` and the
    coverage column report it.
- **U_net** = (rx + tx bytes) of the default-route (ENA) interface ÷ (line rate × billed s).
  - It is computed against both line rates: NetworkCards[0]'s baseline and its peak.
  - `U_net_rx` and `U_net_tx` give each direction alone over the same line rates, in case EC2's
    rates apply per direction. Scott chooses which to use.
  - The sysfs byte counters run from boot, like `/proc/stat`, so network is counted from
    `btime` too.
  - A burst can exceed the baseline rate, so U_net at baseline can exceed 1.
  - Only the default-route interface and NetworkCards[0] are counted.
- **Unobservable windows** count as 0%, and their durations are columns:
  - `launch_time` → `btime`, for all three;
  - `btime` → the first tick, for memory only (CPU and network are counters integrated from
    boot, so this window is counted for them);
  - the last tick → `terminated_at`, for all three.
- A counter that goes backwards (an interface reset) gives an empty cell and a note, never 0.

**The sampler** is `scripts/util-sampler.sh`: dependency-free bash, at 1 Hz.
- **Start.** `scripts/lib/mkstub.sh` splices it into the stub. The stub's first act after
  `set +e` is to write it to `/tmp/ak2-util.sh` and start it, double-forked with no inherited
  stdio. It reads only `/proc` and `/sys`, and runs `ethtool -S` once, so it starts ahead of
  the region assert.
- **Record.** One record per tick goes to `/tmp/ak2-util.tsv`. Its tab-separated record types:
  - `H key value`: the header. It holds the sampling period, btime, clk_tck, ncpu, the
    interface and the cgroup. If the default route only appears later, a later `H iface` line
    records it, and the sampler keeps looking until it does.
  - `S t phase tag …`: raw counters, tagged with the phase in `$AK2_STATE/phase` (`stub` before
    the preamble). The counters are `/proc/stat`'s aggregate line, MemTotal, MemAvailable,
    Shmem, rx/tx bytes, pgfault, pgmajfault, and the task cgroup's `cpu.stat`.
  - `E t start|end name value`: the `ethtool -S` `*_allowance_exceeded` counters.
- **Cost.** No fork per tick: builtins only, and the wait is `read -t` on a private FIFO. In the
  AL2023 test containers the loop used 0.5–2.4 ms of CPU per tick (at most 0.24% of one vCPU).
  Each `ak2_phase` tick is one extra `bash` process.
- **Streaming.** The preamble's pusher sends the record to `log/util.tsv` every 30 s, and at
  exit. The pusher's other uploads, `run.log` and `requests.tsv`, still go every 5 s. Every
  upload is one `aws s3 cp`, a Python CLI process, and costs far more than the sampler. The
  harness's own overhead (the task cgroup's CPU against the workload's) is to be measured on
  the first instance run.
- **TTL kill.** A kill loses at most the last 30 s of the record; `make util-stream-test`
  asserts this.
- **Priority.** The loop renices itself to -10, directly as root or else via `sudo -n renice`,
  so a machine saturated by the workload does not starve it of ticks. Failing both, it carries
  on at its own nice. The header's `H nice` line records the value it got.
- **Phase boundaries.** `ak2_phase` takes one tick at each phase start (`once phase`). The
  interval before it belongs to the previous phase, so the boundaries are exact.
- **End.** `ak2_finish` stops the loop, takes a `final` tick together with the end-of-run
  `ethtool` counters, and pushes the record once more.
- **Fallback.** If the stub could not start the sampler, the preamble starts it and logs a
  WARN. Utilisation is then measured from its first tick.

**At launch**, `run.sh` adds `instance.type_info` to the manifest, from
`describe-instance-types`: vcpus, memory_mib, network_performance, baseline_gbps and
peak_gbps. `launch_time` and `terminated_at` were already recorded.

**After the run**, `scripts/lib/util.py` writes `tables/util.tsv`, and `run-multi.sh` writes the
cohort's. Its rows:
- `node`: one per instance;
- `fleet`: the sums;
- `node-phase`: per phase, plus the three unobservable windows, shown in brackets;
- `fleet-phase`: the phases summed across nodes.

Its columns:
- the utilisations: U_cpu, U_mem_mean and U_mem_peak (with `mem_gap_s`), U_net_baseline and
  U_net_peak, and the per-direction U_net_rx_* and U_net_tx_*;
- the effective cost and the multiplier (1/U) of each;
- the unobservable durations;
- the task cgroup's CPU (spored's service cgroup: the workload plus the harness, without the
  rest of the system);
- pgfault and pgmajfault, so page-fault time can be seen per phase;
- the allowance-counter deltas, tick count and largest tick gap (also per phase), the capacity
  source, and coverage. If the interface's counters first appear on a later tick, that tick's
  since-boot value goes into the boot window, and coverage says so.

A fleet takes only the nodes that have capacity and a billed window, in both numerators and
denominators; any other node is excluded and named. A fleet row's coverage also carries its
nodes' notes. In a cohort's table the node column is the member's run_id. Beside every table,
`tables/util.json` records util.py's commit and every input file with its sha256.

**Useful-work CPU.** The definition asks for the workload's CPU in a named cgroup scope
(`systemd-run --scope`). That is not in place. The bodies do not start the workload in a scope
of its own, and the scope could not be verified here without AWS (the test containers have no
systemd). In its place:
- per-phase CPU from the phase-tagged ticks;
- the task cgroup's `cpu.stat`;
- the engine's own getrusage where `AK2_TIMINGS=1` (`ak2-timing total`);
- upstream's per-run getrusage in the G2 runner.

[util.md](util.md) has the streaming test that `make rehearse` runs first, and the backfill of
the runs that predate the sampler.

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
   call, and the launch must be the box the plan priced. Then it runs the
   [vCPU quota check](#vcpu-quota) for the planned type (also under `DRY_RUN=1`) and records it as
   `quota_check`. It then launches with `-o json`
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
5. The log and `requests.tsv` push every 5 s, the utilisation record (`log/util.tsv`) every 30 s (fixed),
   plus a final push on exit, after the sampler's `final` tick.

## Outputs

`results/<gate>/<run-id>/`: `manifest.json`, `spec.json`, `spec.resolved.json`,
`spawn-plan.txt`, `launch.json`, `launch.err`, `preflight.json`, `log/run.log`, `out/` (what the
spec pushed, plus `requests.tsv`), `spawn/<task_id>/{completion.json,command.log,.exitcode}`,
`completion.json`, `orphans.txt` (the post-run orphan check), `stub.sh` (command[2] as launched),
`log/util.tsv` (the sampler's record), `tables/phases.tsv`, `tables/requests.tsv`,
`tables/util.tsv` (utilisation; `tables/util.log` is util.py's output), plus `decoded/` and `tables/` from
a post script. In S3, the same tree is under
`s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/<gate>/<run-id>/`.

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

## Multi-node runs: make run … NODES=n

```bash
make run GATE=g3 SPEC=runs/g3-std8.json NODES=2            # a cohort of 2 coordinated instances
make run GATE=g3 SPEC=runs/g3-std8.json NODES=2 DRY_RUN=1  # checks + rank 0's plan, launch nothing
```

`NODES` makes `make run` call `scripts/run-multi.sh`, which runs `scripts/run.sh` once per member
of the cohort, in parallel. Each member is a complete single run, with everything above: its own
`results/<gate>/<cohort>-r<k>/`, manifest, log stream, TTL, `cost_limit`, region and Payer
asserts, `drop_caches` probe, and scoped orphan check. A cohort adds this:
- **Identity.** The cohort id is `<UTC>-<sha7>-<rand4>-n<n>`; the random suffix keeps two
  cohorts started in the same second from sharing task ids. Member k's run id is `<cohort>-r<k>`, and
  its manifest has `.cohort = {id, rank, n, prefix, rendezvous, dir}`.
- **Engine env.** run.sh adds these from `AK2_COHORT_*`; a spec cannot set them:
  - `AK2_ENGINE_N`, `AK2_ENGINE_RANK`;
  - `AK2_ENGINE_RENDEZVOUS` = `<cohort prefix>/rendezvous`;
  - `AK2_COHORT_ID`, `AK2_COHORT_PREFIX` = `s3://<results bucket>/aws-kraken2/<gate>/<cohort>`.

  The spec body passes them to `bin/aws-kraken2` ([engine.md](engine.md)). The body takes the
  launch commit from the cohort id (`cut -d- -f3`), not from `AK2_RUN_ID`.
- **Preconditions,** checked before any launch:
  - the spec pins `resources.instance_type` and `placement.availability_zone`, so every member is
    the same box in one AZ;
  - n × `cost_limit` ≤ `AK2_MAX_COST_USD` ($500, the typo ceiling above, not a budget);
  - n × the type's vCPUs, plus every on-demand instance of its quota family already alive in the
    region, fits the family's on-demand vCPU quota ([vCPU quota](#vcpu-quota); also under
    `DRY_RUN=1`). `cohort.json` records it as `quota_check`;
  - the region's default-VPC default security group admits itself (all traffic) and nothing
    beyond 22/tcp and ICMP. `spawn task run` puts every instance in that group, and spawn adds no
    rules (spawn v0.123.0, `cmd/task.go` `taskLaunchConfig`, `pkg/aws/client.go` `Launch`). The
    group is **account-wide**: every `task run` instance in the region, of any project, shares it
    and can reach the engine's ports, which have no authentication (docs/engine.md). us-west-2's
    `sg-5059b179` has the stock self-referencing rule, plus SSH and ICMP from anywhere (account
    configuration). Any other ingress rule makes run-multi refuse the launch.
- **What the instance role can do in the results bucket** (spawn v0.123.0 `cmd/task.go`
  `taskStagingPolicy`). Without `s3_read_write`, it gets only `s3:PutObject`, bucket-wide. That
  covers the run's own writes, including CreateMultipartUpload, UploadPart and
  CompleteMultipartUpload. A cohort spec also lists the bucket in `resources.s3_read_write`, so
  members can read each other's rendezvous records. That grant is `GetObject`,
  `GetObjectVersion`, `PutObject` and `DeleteObject` on the whole bucket, plus `ListBucket` and
  `GetBucketLocation`. Neither grant includes `s3:AbortMultipartUpload`, so only the launch host
  can abort an upload.
- **Fail fast.** Once any member's run.sh exits non-zero while others are still running, the
  others' instances are terminated (found by their `spawn:task-id` tag). The sweep repeats on
  every monitor pass after that, so a member still being sized or launched is caught when its
  instance appears. Their run.sh then finalise as for any terminated instance, and
  `cohort.json` records `terminated_early`. The spec body stops a member at its first failed
  case.
- **Process groups.** Each member driver runs in its own process group (`set -m`; macOS has no
  `setsid`). So the driver and the `spawn task run` it may be in the middle of (sizing takes
  minutes) can be signalled together, and a launch can never land after the cohort has ended.
- **On every exit** (normal, error, INT, TERM or HUP), the `finish` trap does the following, in
  this order:
  - if the cohort did not end normally: TERM every member driver's process group, wait (KILL
    after 60 s). Their run dirs may then need `scripts/refinalise.sh`;
  - sweep: terminate every member instance still alive or shutting down (by tag), `aws ec2 wait
    instance-terminated` for them, then sweep again and wait for anything the second sweep found;
  - only then abort unfinished multipart uploads under the cohort prefix, so an instance that was
    shutting down cannot start an upload after the abort. The bucket's lifecycle rule would
    abort them after 7 days; this does it at once, so no parts are billed in between;
  - it fetches the cohort prefix (rendezvous records) to `results/<gate>/<cohort>/prefix/` and
    tags it. The emitter's outputs under `out/` are not fetched: sample outputs do not belong in
    git. `outputs.tsv` lists each output's key, VersionId (the bucket is versioned), size and
    ETag. Their byte-identity is checked on the instance and recorded in the members'
    `out/identity.tsv`; a file only one side wrote counts as a difference;
  - it writes `results/<gate>/<cohort>/cohort.json`: members (run id, exit, instance, AZ, cost,
    finalised), `cost_usd` (the sum of the members' costs), `ended`, `terminated_early`,
    `sweep_failures` (every describe, terminate or wait that failed) and the multipart abort
    counts;
  - it writes the fleet's `tables/util.tsv` from the members' manifests and `log/util.tsv`
    ("Utilisation" above);
  - it runs the **global** `make orphans`.

  Each member's driver output is in `rank-<k>.run.log`.
- **Exit:** the worst member exit. Otherwise 3 if orphans were found, 4 if the prefix could not be
  fetched, 5 if an unfinished upload could not be listed or aborted, 6 if a sweep failed, and 130,
  143 or 129 when interrupted. `make test` runs `scripts/lib/run_multi_test.sh`, a stub
  simulation with a stubbed `aws` and stub member drivers. It covers TERM and INT before a late
  launch, INT after the launches, a normal end, fail fast with a late launch, a failing describe,
  and an unfinished upload.

**Never rewrite cited history.** `manifest.json` records the launch commit, so do not squash or
rebase commits that a run under `results/` cites. Merge them as they are.
