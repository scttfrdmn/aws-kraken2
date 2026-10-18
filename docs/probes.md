# G3 probes: upstream's staging, S3 contention and decompression (#25)

Three cheap AWS probes and one local benchmark measure the inputs that the upstream arms of
`make g3-frontier` would otherwise assume. Scott approved them on 2026-10-08 in place of the
validation run.

| probe | spec / script | node | what it measures |
|---|---|---|---|
| (c) decompression | `runs/g3-probe-decomp-c8g.4xlarge.json` (`scripts/g3/probe-decomp.body.sh`) | 1 × c8g.4xlarge | gzip, pigz -p 16, igzip, rapidgzip -P 16/-P 8 on SRR5935773, sequential and concurrent mates, output identity against gzip -dc |
| (a) staging | `runs/g3-probe-stage-x8g.24xlarge.json` (`scripts/g3/probe-stage.body.sh`) | 1 × x8g.24xlarge | RODA hash.k2d onto tmpfs: rget sweep, whole-object rget and s5cmd writes, each ETag check timed separately, an aws s3 cp (CRT) rate sample |
| (b) contention | `runs/g3-probe-cont-c8gn.4xlarge.json` (`scripts/g3/probe-cont.body.sh`) | 64 × c8gn.4xlarge, one cohort | concurrent ranged GETs of hash.k2d to /dev/null at N = 1, 16, 32, 64, 60 s each |
| (d) #44 fix speed | `scripts/g3/hitbench.sh [PRE] [POST]` | local | our classifier before the fix (3201a75) and after, SRR062634 8M pairs against Standard-8, warm, alternating |
| (f) classic `aws s3 cp` rate | `runs/g3-probe-awscp-r8gd.48xlarge.json` (`scripts/g3/probe-awscp.body.sh`) | 1 × r8gd.48xlarge | S0's staging of hash.k2d with the AMI's aws CLI as shipped onto one NVMe device, for 20 min or 300 GiB; sizes S0-T1 and S0-Tv's TTL ("The classic aws s3 cp rate" below) |
| (g) rapidgzip crash | `runs/g3-probe-rgcrash-r8g.16xlarge.json` (`scripts/g3/probe-rgcrash.body.sh`) | 1 × r8g.16xlarge | `lad_identity` exactly (6 lanes of gzip -dc then rapidgzip 0.14.5 -P 8 on the c10 files), until 15 min before the TTL, with core capture, gdb and the null's resolution ("The rapidgzip crash probe" below) |
| (h) rapidgzip fix | `runs/g3-probe-rgfix-r8g.16xlarge.json` (`scripts/g3/probe-rgfix.body.sh`, `scripts/g3/rg-build.sh`) | 1 × r8g.16xlarge | probe (g)'s conditions with two candidate fixes alternating per job: 0.14.5 built without rpmalloc, and the 0.16.0 wheel; P(no crash) at (g)'s 9/3588 per variant ("The rapidgzip fix probe" below) |
| (e) host tunes (#41) | `runs/g3-probe-tune-x8g.24xlarge.json` (`scripts/g3/probe-tune.body.sh`, `scripts/g3/hosttune.sh`) | 1 × x8g.24xlarge | load and classify time under each candidate host-tune set, upstream `-M` on tmpfs and ours' engine N = 1, with fragmentation counters; fixes S3's set ("Host tunes" below) |

## Running them

Run them cheapest first. Rehearse each one, then launch it from a pushed commit. Check for
orphans after each run.

```bash
make rehearse SPEC=runs/g3-probe-decomp-c8g.4xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-decomp-c8g.4xlarge.json
make rehearse SPEC=runs/g3-probe-stage-x8g.24xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-stage-x8g.24xlarge.json
make rehearse SPEC=runs/g3-probe-cont-c8gn.4xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-cont-c8gn.4xlarge.json NODES=64
make orphans
scripts/g3/hitbench.sh 3201a75 HEAD
make g3-frontier
```

- **Specs** come from `scripts/g3/mkspec-u.sh probe-<kind> <type> <TTL min> <body> us-west-2b`.
- **Rehearsal:** `scripts/lib/probe_rehearse.sh` runs each body unmodified against local
  stand-ins:
  - S3 is replaced by the stub aws;
  - hash.k2d is replaced by a 320 MiB random file with a real multipart ETag, served with Range
    and If-Match by `k2probe serve-file`;
  - s5cmd is replaced by a stub;
  - the contention probe runs as three concurrent members.
  It passes on observed output: streamed lines equal pushed lines, and the counts and identity
  assertions in the script's header hold.
- **Tables:** the post scripts run `scripts/lib/probe_tables.py`, writing
  `tables/probe-{decomp,decomp-conc,staging,contention,contention-nodes}.tsv`.

## The classic `aws s3 cp` rate (probe f, before the ladder)

**Why:** S0-T1 and S0-Tv stage RODA's 1.19 TB hash.k2d with the AMI's aws CLI as shipped
(`awscp-default`), which resolves to the classic transfer client on r8gd.48xlarge (lever.sh's
auto rule). That rate has never been measured, so their 360 min TTL is a guess. This probe
measures it first, for at most 40 min.

```bash
make rehearse SPEC=runs/g3-probe-awscp-r8gd.48xlarge.json
DRY_RUN=1 make run GATE=g3 SPEC=runs/g3-probe-awscp-r8gd.48xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-awscp-r8gd.48xlarge.json      # Scott's call
make orphans
```

**What it does, as S0 does it:**
- `lv_nvme single` mounts the first instance-store device.
- It uses lever.sh's `default` client, recorded as kind `client` with `resolved` and `how`.
- It runs `lv_stage_db awscp-default`'s own command line: a signed, then anonymous, head-object,
  then `aws s3 cp --only-show-errors` of hash.k2d.

`drop_caches` runs before the copy. The copy runs until 20 min or 300 GiB received, whichever
comes first (or the object completes). Then it is stopped (TERM, then KILL if it has not exited within 30 s, recorded as `killed_hard`) and the partial file is removed.

**Lines** (streamed as `probe-awscp {json}` and in `out/awscp.jsonl`, pushed every 30 s):
- `client` and `config`;
- `progress` every 10 s:
  - `bytes`: received on the default-route NIC since the copy started; `bytes_basis` says so;
  - `allocated_bytes`: what the NVMe holds;
  - `s`;
  - `gbps`: gigabits/s, cumulative;
  - `interval_gbps`: since the last line;
  - `gb_per_s`: GB/s;
  - `dirty_kb` and `writeback_kb`: from /proc/meminfo. If they grow, the NVMe, not the network, limits the rate.
- `done`:
  - `stopped_by`: time, bytes, complete or failed;
  - `steady_gbps`: from the first line past 60 s to the end;
  - `est_object_s` and `est_object_s_steady`: the whole object at those rates.

**Tables** (`scripts/post/g3-probe-awscp-r8gd.48xlarge.sh` → `probe_tables.py awscp`):
- `tables/probe-awscp.tsv`: one row, with the resolved client, the rates, the estimates, and
  `est_over_s0_ttl` (the estimate over S0's 360 min TTL);
- `tables/probe-awscp-progress.tsv`: the series.

**Cost:** TTL 40 min, `cost_limit` = TTL × the on-demand price ($14.11/h: $9.41).

**Rehearsal** (`probe_rehearse.sh`, kind awscp): three runs on the 320 MiB stand-in:
- a throttled copy stopped by the bytes limit;
- one stopped by the time limit;
- one that ignores TERM, so the stop KILLs it 30 s later (`killed_hard`);
- one that completes.

The seams are `AK2_REHEARSE_AWSCP_S`, `_BYTES`, `_EVERY` and lever.sh's `NVME`, plus the stub
aws's `AK2T_COPY_BPS`. Each run must:
- stream lines equal to the pushed ones;
- have at least 2 progress lines (1 for the complete run) and the right `stopped_by`;
- record the client;
- count GetObject;
- leave nothing on the NVMe;
- give both tables.

**Not covered locally:** the real CLI's rate and its client resolution on r8gd.48xlarge (the
stub resolves to `unknown`), and the NIC counter (the host has no /proc; `bytes_basis` is then
`allocated`).

## The rapidgzip crash probe (probe g)

**Why:** in about 1,553 identity-step decompressions on the c10 ladder (`lad_identity` in
`scripts/g3/ladder.body.sh`), rapidgzip 0.14.5 exited 139 (SIGSEGV) twice:
- O4b-if4 (r8g.16xlarge, nproc 64), `SRR5935745_1.fastq.gz`, `-P 8`;
- S6 c10 rep 2 (nproc 96), `SRR5935748_2.fastq.gz`.

Both runs stalled about 300 s before the exit. In util.tsv, one vCPU sat at 100% nice outside
the job cgroup. That fits systemd-coredump (Nice=9, RuntimeMaxSec=5min) being killed, so the core
was probably lost. The crashed outputs are not a prefix of the right stream, so this looks like
memory corruption or a race, not a truncation. 2,700 runs on an Apple-silicon podman VM did not
reproduce it. This probe tries to reproduce it on the crashing type, with a core and a backtrace.
Scott approved it on 2026-10-18 ("Graviton4 repro probe").

```bash
make rehearse SPEC=runs/g3-probe-rgcrash-r8g.16xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-rgcrash-r8g.16xlarge.json      # Scott's call
make orphans
```

**One question.** Does `lad_identity`'s own load on r8g.16xlarge reproduce 0.14.5's crash, at a
job count large enough that a null result means something? Two earlier designs were narrowed
after review:
- **No stress lanes.** Extra rapidgzip-only lanes added 16 to 32 threads to the ladder's 48, so
  the load was no longer the ladder's.
- **No second version.** Splitting the jobs between 0.14.5 and 0.16.0 halved each version's count,
  so neither null could resolve.

So the probe runs only `lad_identity`, and only the version that crashed.

**0.16.0 is a possible follow-up run.** It would use the same body with the version swapped.
Its pin is the cp39 manylinux aarch64 wheel's sha256, from PyPI's JSON API (checked 2026-10-18):
`2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d`.

**What it does:**
1. **Setup.** dnf installs gdb and zstd. `dnf debuginfo-install` fetches python3, glibc and
   libstdc++ debuginfo; this is best effort and recorded. rapidgzip 0.14.5 comes from lever.sh's
   `lv__rg_ensure` (pip `--require-hashes`). The `tool` line records the wheel, the `.so` and their
   sha256s. The `.so`, its python and libpython go to `out/bundle-0.14.5.tar.zst`, so a core can be
   opened offline.
2. **Core capture.** `ulimit -c unlimited` is set, and `kernel.core_pattern` is set to
   `/dev/shm/cores/core.%p.%e.%t`; the previous value is recorded and restored at the end. A
   positive control follows: the same python SIGSEGVs itself, and the run continues only if a
   core appears and gdb reads frames from it (the `core-control` line). Without that control,
   "no core" would not be evidence of anything.
3. **Inputs.** The c10 cohort's 20 gz files (`runs.tsv` ranks 1 to 10, 10.6 GB) go to
   `/dev/shm`, each checked against its sha256 metadata. GNU `gzip -dc | sha256sum` runs once per
   file to give the reference.
4. **The loop: `lad_identity`, repeated.**
   - There are IDL = nproc / (P + 2) lanes, with P = 8: 6 on r8g.16xlarge. The body refuses to
     run there with any other count.
   - Lane l takes jobs n = l + IDL·k, and job n's file is c10 file n mod 20.
   - Each job runs `gzip -dc FILE | sha256sum`, then `rapidgzip -d -c -P 8 FILE | sha256sum` on the
     same file. That gives about 48 rapidgzip threads mixed with single-thread gzip, as on the
     ladder.
   - Each rapidgzip run has a 300 s timeout that sends SIGABRT, so a hang also leaves a core.
   - This is not a timing probe, so there is no drop_caches. Page-cache state is logged in
     `meminfo` lines.
5. **When it stops.** It starts jobs until the latest time that still leaves at least 15 min
   before the 150 min TTL (Scott, 2026-10-18: TTL 150 min, raised from 120 so that a null
   resolves), after:
   - a full 300 s timeout and its 30 s kill grace;
   - one gzip pass (the slowest reference pass);
   - 120 s for gdb and the pushes.

   The TTL is counted from launch at the earliest, and launch is taken as 120 s before boot.
   That puts the last start about 125 min after boot.
6. **On any failure** (a non-zero exit, or either tool's sha256 not the reference):
   - its stderr and the matching dmesg lines are recorded;
   - gdb runs on its core (`info sharedlibrary`, `p $_siginfo`, `bt`, `thread apply all bt`,
     `info registers`, `x/16i $pc`);
   - the first 6 cores are zstd-compressed and pushed;
   - the loop carries on.
7. **Tally.** The tally and the jsonl are pushed every 100 jobs and after every failure.

**Resolution (Law 4).** At the ladder's rate, 2/1553 (about 1.3e-3 per step), N jobs see no
crash with probability exp(−(2/1553)·N). That is 0.05 at N ≈ 2,330.
- **Before the loop,** the `plan` line streams the expected N: IDL × the loop's seconds / 14.6 s.
  The 14.6 s is the review's estimate of one gzip + rapidgzip identity step on a 64-vCPU host.
- **Every 5 min,** a `progress` line re-projects N from the probe's own measured mean step.
- **At the end,** the `summary` line gives the verdict.

With a 150 min TTL the loop runs for about 6,900 s, so the plan expects about
6 × 6,900 / 14.6 ≈ 2,840 jobs and P(no crash) ≈ 0.026. **A null is then expected to resolve at
0.05**, as long as the measured step stays under about 17.8 s (6 × 6,900 / 2,330). The 6,900 s
comes from the stop rule, less about 10 min of boot, setup, fetch and reference. At 120 min the
loop would have run about 5,100 s, giving about 2,100 jobs and P ≈ 0.07, which does not
resolve. A crash answers the question either way.

**Lines** (streamed as `probe-rgcrash {json}` and in `out/rgcrash.jsonl`):

| kind | what it records |
|---|---|
| `tool` | rapidgzip 0.14.5: wheel, sha256s, `.so`, python |
| `host` | gdb, debuginfo result, kernel, CPU, nproc, `lanes`, `P`, glibc |
| `core-control` | the previous and new core_pattern, ulimits, the control's core and gdb frame count, `ok` |
| `reference` | 20 lines: the GNU gzip sha256, exit and seconds per file |
| `plan` | `lanes`, `loop_s`, `last_start`, `ttl_rule_last_start`, `ttl_end_est`, `worst_end_before_ttl_s`, `body_start_plus_95min`, `gzip_max_s`, `prior_job_s`, `ladder_rate`, `expected_jobs`, `p_no_crash_expected`, `resolves_expected` |
| `progress` | every 5 min: `jobs`, `crashes`, `failures`, `mean_step_s`, `projected_jobs`, `p_no_crash_projected`, `resolves_projected` |
| `meminfo` | after-fetch, loop-start, every 5 min, end |
| `job` | one per job: `n`, `lane`, `mode` (always identity), `version`, `file`, `P`, `exit`, `signal`, `timeout`, `sha256`, `match` (against the reference), `seconds`, `pid`, `gzip_sha256`, `gzip_exit`, `gzip_match`, `gzip_seconds`, `step_seconds` |
| `failure` | one per failed job: `core`, `core_bytes`, `core_pushed` (its out/ key, or null after the first 6), `gdb_frames`, `fault` (si_addr), `stderr`, `dmesg` |
| `summary` | `jobs`, `crashes` (any signal), `sigsegv`, `timeouts`, `nonzero_exit`, `wrong_sha`, `wrong_sha_exit0`, `gzip_mismatch`, `crash_rate`, `mean_step_s`, `ladder_rate`, `p_no_crash_at_ladder_rate`, `null_resolves`, `verdict` |
| `restore` | core_pattern back to its previous value (`restored`) |

gdb's output also streams as `rgcrash-gdb <n> | ...` lines in the run log, and is pushed as
`out/gdb/<n>.txt`. Cores are pushed as `out/cores/core.<pid>.<comm>.<t>-job<n>-0.14.5.zst`.

**Files** (in the run's `out/`):
- `rgcrash.jsonl`;
- `rgcrash-tally.tsv`: version × P, with jobs, nonzero_exit, crashes, timeouts, wrong_sha and
  gzip_mismatch;
- `gdb/`, `cores/`;
- `bundle-0.14.5.tar.zst`.

**How to read it:** the `summary` line's `verdict` is one of:
- **reproduced** (`crashes` > 0): the `failure` lines and `gdb/<n>.txt` hold the backtrace. The
  faulting thread is the one gdb shows first, in `bt`.
- **not reproduced; the null resolves**: `p_no_crash_at_ladder_rate` ≤ 0.05. Under the ladder's
  own load on this type, 0.14.5's crash rate is then below the ladder's at the 5% level.
- **not reproduced; the null does NOT resolve**: that is no evidence either way.

Two more things to check:
- **A `wrong_sha_exit0` above 0** means wrong output with a clean exit. That is worse than a
  crash, because the identity step catches it only through the sha256.
- **To open a core offline,** on AL2023 aarch64, unpack the bundle and run `gdb <python> <core>`,
  with `set solib-search-path` pointing at the unpacked `.so`.

**Cost:** TTL 150 min (Scott, 2026-10-18), `cost_limit` = TTL × the on-demand price
($3.77024/h: $9.43, from
`scripts/g3/mkspec-u.sh probe-rgcrash r8g.16xlarge 150 scripts/g3/probe-rgcrash.body.sh us-west-2b`).

**Rehearsal** (`scripts/lib/rgcrash_rehearse.sh`, through `probe_rehearse.sh`): the body runs
unmodified in an AL2023 aarch64 container on the rootful podman VM. The container is privileged,
because core_pattern is the VM kernel's. It runs as ec2-user under `bash -e -c`, after the probe
helpers' stand-ins.
- **Real:** dnf, gdb, the debuginfo install, the pip `--require-hashes` install from PyPI, sysctl
  and the cores.
- **Stand-ins:** the stub aws over a directory is S3. The c10 names hold the small real read sets
  from `.cache/reads`.
- **Seams:** the VM has 8 CPUs, so `AK2_REHEARSE_LANES=6` gives the r8g.16xlarge lane count.
  `AK2_REHEARSE_LOOP_S=150` replaces the TTL rule, and `AK2_REHEARSE_PROGRESS_S=30`.
- **The induced crashes:** the host sends SIGSEGV to 3 running rapidgzip processes, with
  `AK2_REHEARSE_MAXCORES=2`.

It passes on observed output:
- the tool line carries lever.sh's pinned wheel sha256;
- the host line shows 6 lanes;
- the core control is ok;
- the plan line's `p_no_crash_expected` equals exp(−(2/1553)·`expected_jobs`), and there are at
  least 2 progress lines with a measured mean step;
- the job lines streamed equal the pushed ones;
- every job is `lad_identity`'s: 0.14.5, -P 8, lane = n mod 6, file = c10 file n mod 20, and
  gzip's sha256 equals the reference;
- exactly the killed jobs fail with exit 139, and each has a core, gdb frames, and gdb output
  streamed and pushed;
- 2 valid zstd cores are pushed;
- every other job matches the reference;
- there is one summary line, with verdict `reproduced`, the right p, and crashes = 3;
- the VM's core_pattern after the run equals its value before.

A kill that lands after the last write leaves a correct sha256, so the check uses the exit status
only. The TTL rule itself is not exercised in the rehearsal: the VM's uptime is not an instance's.
Its inputs and result are in the `plan` line (`ttl_rule_last_start`, `worst_end_before_ttl_s`).

## The rapidgzip fix probe (probe h)

**Why:** probe (g) (`results/g3/20261018-184334-cc920a8`) reproduced the crash. rapidgzip 0.14.5
under `lad_identity` on r8g.16xlarge had 9 SIGSEGVs in 3,588 jobs (0.25%), and every one gave a
wrong sha256.
- **6 cores** stop at `_rpmalloc_deallocate_small_or_medium` (rpmalloc.c:814). The main thread
  is freeing `ChunkData` buffers through `Cache<…>::clear` ← `BlockFetcher::insertIntoCache` ←
  `GzipChunkFetcher::processNextChunk`.
- **3 cores** stop at `__aarch64_cas4_acq`.

The diagnosis is a race in 0.14.5's bundled rpmalloc on aarch64. Scott approved this follow-up on
2026-10-18. It runs the same conditions with two candidate fixes, about half the jobs each,
alternating job by job within the identity lanes.

```bash
make rehearse SPEC=runs/g3-probe-rgfix-r8g.16xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-rgfix-r8g.16xlarge.json      # Scott's call
make orphans
```

**The variants:**

| variant | what | rpmalloc | ISA-L | from |
|---|---|---|---|---|
| a `0.14.5-norpmalloc` | 0.14.5 built from its sdist | off | off | `scripts/g3/rg-build.sh` |
| b `0.16.0` | the PyPI cp39 manylinux aarch64 wheel, `--require-hashes` (`2c3d75cb…`) | on (a newer rpmalloc) | on | PyPI |

**ISA-L cannot be on in (a).** 0.14.5 cannot build ISA-L on aarch64:
- its `setup.py` builds ISA-L only with nasm on x86_64 (`canBuildIsal`);
- its CMake sets `WITH_ISAL OFF` on ARM ("ARM compilation not yet implemented").

So the crashing PyPI aarch64 wheel has no ISA-L either (`nm -D`: 0 ISA-L symbols, 23 rpmalloc
functions). That makes (a) a one-lever change from the crash: rpmalloc off.

(b) changes the release, the rpmalloc version and ISA-L together. A clean (b) shows that 0.16.0
works, not why. 0.16.0's `setup.py` builds ISA-L on aarch64, and its wheel exports 64 ISA-L
symbols. ISA-L on aarch64 for the input-path sweep (#90) therefore comes from 0.16.0, not from a
0.14.5 build.

**`scripts/g3/rg-build.sh OUTDIR [S3_CACHE_PREFIX]`** is the one recipe for (a). Probe (h) uses
it, and so will #90, so both run the same artefact.
- **Pins:**
  - the sdist `rapidgzip-0.14.5.tar.gz` by sha256
    (`faed4601…`, `pip download --no-binary --require-hashes`);
  - the build deps by `--require-hashes`: setuptools 71.1.0, wheel 0.44.0 and Cython 3.0.12
    (inside the sdist's pyproject bounds);
  - AL2023's gcc-c++ (11.5.0) and python3-devel;
  - `pip wheel --no-build-isolation` with `RAPIDGZIP_BUILD_RPMALLOC=disable` and
    `RAPIDGZIP_BUILD_ISAL=disable`.
- **Verification:** the build log must say `rpmalloc: disable` and `isal: disable`. The `.so`
  must export 0 rpmalloc functions and 0 ISA-L symbols, `--oss-attributions` must list neither,
  and the version must be 0.14.5. Anything else is a failure.
- **Cache:** the recipe's sha256 (the script, the pins, gcc, python and the arch) is the key, under
  `s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/rg-build/<recipe>/` (wheel and
  `build.json`).
  - A hit downloads the wheel and checks its sha256.
  - A miss builds the wheel and stores it.
  - The wheel is not bit-reproducible: two builds differ in sha256. The cache is what makes
    later runs use the identical artefact.
- **Build time:** 140 s in the rehearsal container (`build_s`, dnf included). Probe (h) measures it,
  and the plan line records it.

**What it does:** the same as probe (g), with these differences:
- **The build.** rg-build.sh runs first. Its record streams as the `rg-build` line, and the build
  log is pushed. If the build fails, the probe still runs: every job uses (b), (a)'s summary says
  `not run: build failed`, and the tail of the build log streams as `rg-build-log | …` lines.
- **The variant per job.** It is `(k + lane) mod 2` within lad_identity's lanes (n = l + 6k,
  gzip -dc then rapidgzip -P 8 on the same file).
- **The reference rate** is probe (g)'s measured 9/3588. It is the 0.14.5 wheel's crash rate under
  this exact load. There is no 0.14.5-wheel control in this run, because the budget covers the two
  candidates only, so the reference is the committed record.
- **The plan line** adds `build_s`, `setup_s` and `per_variant` (expected jobs and
  P(no crash) = exp(−(9/3588)·n)). The expected total uses probe (g)'s measured mean step,
  12.3 s. Progress lines re-project per variant from this run's steps.
- **The summary** has one line per variant: `ran`, `build`, `jobs`, `crashes`, …,
  `p_no_crash_at_reference_rate`, `null_resolves` and a `verdict`. The verdict is one of: *crashed:
  not a fix*; *no crash; the null resolves … the fix is supported*; *no crash; the null does NOT
  resolve*; *not run: build failed*.
- **Stop rule and margins:** the same as probe (g), with TTL 150 min and cost_limit $9.43.

**Resolution:** probe (g)'s loop ran 7,378 s. Probe (h) loses the build (about 3 min), so about
7,200 s are left: 6 × 7,200 / 12.3 ≈ 3,500 jobs, about 1,750 per variant. At 9/3588, P(no crash) ≈
exp(−4.4) ≈ 0.012 per variant, so each variant's null is expected to resolve. It needs about 1,195
jobs per variant for 0.05.

**Lines** (`probe-rgfix {json}`, and `out/rgfix.jsonl`): `rg-build`, `tool` (per variant: wheel,
sha256s, `rpmalloc_functions`, `isal_symbols`, `oss_attributions`), `host` (`variants`),
`core-control`, `reference`, `plan`, `progress`, `meminfo`, `job` (with `variant`), `failure`
(with `variant` and `frame0`, gdb's `#0` line), `summary` × 2, and `restore`. gdb's output streams
as `rgfix-gdb <n> | …` lines. Files: `rgfix.jsonl`, `rgfix-tally.tsv` (variant × version),
`rg-build.log`, the built wheel, `gdb/`, `cores/` and the 2 bundles.

**How to read it:**
- **(a) clean and resolving** supports rpmalloc as the cause, and turning it off as a fix for
  0.14.5.
- **(a) crashing** means rpmalloc is not the whole story. Read `frame0` in its failures.
- **(b)** says whether 0.16.0 can replace 0.14.5 (S5, and #90's ISA-L arm), not why.

**Rehearsal** (`scripts/lib/rgfix_rehearse.sh`, through `probe_rehearse.sh`): the body runs
unmodified on AL2023 aarch64 containers (rootful podman, privileged) as ec2-user under
`bash -e -c`, with a real source build. There are three runs:
1. **The probe,** with a 150 s loop and 6 lanes. The host sends SIGSEGV to 3 running rapidgzip
   processes (a, b, a), with MAXCORES=2.
2. **A failed build,** via rg-build.sh's seam `AK2_REHEARSE_RGBUILD_SDIST_SHA256`, a wrong sdist
   pin. (b) must still run.
3. **rg-build.sh alone,** after run 1. It must be a cache hit giving run 1's wheel.

The checks are in the script's header; they all run on observed output. They include:
- the build is verified, with 0 rpmalloc and 0 ISA-L symbols;
- (b)'s ISA-L symbols are present;
- the variant alternation is exactly `(k + lane) mod 2`;
- exactly the killed jobs fail, with cores and gdb output;
- the summaries are a 2 / b 1 crashed, with the right p;
- the VM's core_pattern is restored;
- in run 2, (a) is `not run` and every job is (b);
- run 3 is a cache hit with the same sha256.

## How the frontier uses them

`scripts/lib/g3_frontier.py` reads every `results/g3/*/tables/probe-*.tsv` and adds labelled
upstream variants. The measured single-node and single-rate points stay alongside them.

- **Staging at probe (a)'s rate:** the fastest complete write whose ETag check passed.
- **Staging capped by contention:** probe (a)'s rate × f(N), where f(N) is the slowest node's
  rate at N divided by a lone node's rate, from probe (b).
- **Decompression options:**
  - each identical tool's time relative to pigz, both run sequentially as U1's preparation was;
  - decompression pipelined ahead of classify;
  - gz streamed through the wrapper's pipes, using the tool's concurrent-mates time.

**Hygiene:**
- Neither (c) nor (a) reads from storage: (c)'s inputs sit on /dev/shm and (a) writes to tmpfs,
  so `drop_caches` does not apply.
- (b) synchronises its stages from the members' clocks via rendezvous records in the cohort prefix.

## Host tunes and the tune-selection probe (#41)

Ladder 1's S3 rung applies host tunes to upstream's S2b context (a huge=always tmpfs with `-M`).
Which set it uses is fixed by this probe. G2 saw upstream's resident load drift from about 37 s
to 240-300 s within one run, with about 27% of the load in direct THP compaction (#41).

### `scripts/g3/hosttune.sh`

A spec body sources it after the clone. Each function returns a status and never exits the body.

| function | what it does |
|---|---|
| `ht_init` | records the boot value of every knob, once, in `$HT_DIR/base.tsv` |
| `ht_apply SET [DEV...]` | applies a named or inline set (`key=value,...`), then its timed pre-compaction step |
| `ht_restore` | writes back the boot value of every knob that differs from it |
| `ht_record LABEL` | appends `/proc/buddyinfo`, the `compact_*` and `thp_*` lines of `/proc/vmstat`, meminfo's huge-page lines and the THP settings to `hosttune.txt`, and a JSON summary to `hosttune.jsonl`; both are pushed at once |

**Knobs:**
- `enabled` and `defrag`: `/sys/kernel/mm/transparent_hugepage/`.
- `proactiveness`: `vm.compaction_proactiveness`.
- `ra`: `read_ahead_kb` of each given block device (`HT_BLOCKDEVS`).
- `precompact`: a step, not a setting. It runs `echo 1 > /proc/sys/vm/compact_memory`, and the
  time it takes is `HT_PRECOMPACT_S`.

**How it records and fails:**
- `ht_apply` writes one row per knob to `hosttune-apply.tsv`: the value before, the wanted value,
  the value after, and a status. The rows are echoed as `ht-apply ...` and pushed.
- A set that does not read back as wanted returns non-zero with `HT_APPLIED=false`. It is loud,
  not silent.
- `none` never writes. It returns non-zero only if the host is not at its boot values. Call
  `ht_restore` first.
- `HT_ROOT` prefixes every path, so a test or a rehearsal can point it at a fake tree.

`make hosttune-test` (`scripts/lib/hosttune_test.sh`) runs it on an AL2023 container (podman,
rootful). The container uses the kernel's own `/proc` and `/sys`, and the test runs under
`bash -e -c` with `set +e`, as a body does. It checks:
- `ht_apply none` makes no write and no sudo or tee call, and leaves every knob unchanged;
- `ht_record` pushes on every call, and each upload is longer than the one before;
- a set that cannot be written (here `/sys` is read-only) fails loudly and changes nothing;
- on a fake tree, `none` leaves every file's content and mtime unchanged, and a set and its
  restore are written and recorded.

### Candidate sets

AL2023 on x8g boots kernel 6.18 with `enabled=madvise` and `defrag=madvise`. Under those settings:
- regime (b)'s `MADV_HUGEPAGE` faults compact directly when no free 2 MiB block is left;
- regime (a)'s tmpfs writes have no VMA, so they take a huge page only if one is free, and
  otherwise fall back to base pages without compacting.

| set | knobs | rationale |
|---|---|---|
| `none` | nothing | the baseline (S2b as it is) |
| `precompact` | `compact_memory` once, just before the load (its seconds count in the total) | defragments free memory once, ahead of 1.1 TiB of huge-page allocations, instead of stalling in direct compaction during them |
| `proactive` | `compaction_proactiveness=100` (boot 20) | kcompactd keeps fragmentation low in the background, so faults find free 2 MiB blocks |
| `defer` | `defrag=defer` | no direct compaction, even for `MADV_HUGEPAGE`. This removes G2's compaction stall from (b)'s load, at the risk of fewer huge pages (the classify guard catches that). For (a), a failed huge allocation wakes kswapd and kcompactd |
| `defermadv` | `defrag=defer+madvise` (named in #41) | (b) keeps direct compaction; (a) behaves as under `defer`. It is measured rather than assumed equal to either |
| `always` | `defrag=always` | the only setting under which (a)'s tmpfs writes compact directly, which maximises (a)'s huge-page coverage at the cost of staging time |

**Null controls in (b):** for a madvised fault, v6.18's `vma_thp_gfp_mask` gives `always`,
`defer+madvise` and `madvise` (`none`) the same direct-compaction behaviour. So in regime (b),
`always` and `defermadv` are null controls for `none`. Read any "win" among those three cells as
noise: it shows what the probe's spread can produce by chance.

Out of scope:
- **`read_ahead_kb`:** neither regime reads a block device (the table comes over the network,
  the inputs sit on tmpfs), so no candidate sets it. `ht_apply` supports it for the NVMe rungs.
- **`enabled`:** it stays at `madvise`. Both regimes ask for huge pages explicitly
  (huge=always, `MADV_HUGEPAGE`).

### The probe: `runs/g3-probe-tune-x8g.24xlarge.json`

The probe is one x8g.24xlarge in us-west-2c (2b had no x8g.24xlarge capacity on 2026-10-09, run 20261009-222826-d410776; 2a has failed before). Its body is `scripts/g3/probe-tune.body.sh`, and
its spec comes from `scripts/g3/mkspec-u.sh probe-tune x8g.24xlarge 360 ... us-west-2c SRR5935740`
(the accession goes into `env.AK2_ACCESSIONS`, and so into the manifest). The
spec header registers the plan, the selection rule and the resolution check.

**Regimes:**
- **(a)** upstream at the pin. RODA's `hash.k2d` is staged by s5cmd onto a huge=always tmpfs,
  then classified with `-M`.
- **(b)** ours, engine N = 1. The table is loaded by 48 ranged GETs into `MADV_HUGEPAGE` memory.

**Plan:**
- Each regime classifies the same fixed sample, SRR5935740 as fq, at `--threads $(nproc)`.
- First a warm-up pair, `none` on (a) then on (b), labelled `warmup`. It is streamed and
  recorded but never counted in a cell, so the fresh-boot trial cannot widen range(none, a) on
  its own.
- Then 6 sets × 2 regimes × 3 repetitions = 36 cold trials, 38 in all.
- Each repetition runs all 12 cells before the next one starts, in the fixed order `SCHED` that
  the body registers. That order is a searched design, not a rotation:
  - every set's a-before-b order flips from one repetition to the next;
  - each cell's 3 trials follow 3 different predecessors, of both regimes;
  - every cell, in both regimes, has exactly 2 of its 3 trials right after a trial of the
    other regime. So a cross-regime carry-over, such as (a)'s staging right after (b) freed
    1.1 TB of anonymous memory, weighs on every set alike. The previous `SCHED` gave `always`
    on (a) only 1 such trial against 2 for the others, which with n = 3 decides its median;
  - `probe-tune-trials.tsv` records `prev_regime` and `prev_set` for every trial, so any
    carry-over can be read from the record;
  - the sets' mean positions differ by at most 1 trial, and the cells' by at most 3;
  - no regime runs 3 times in a row.
- `tune_tables.py --self-test` (`make test`) reads `SCHED` from the body and asserts these
  properties. It also asserts that the rotated design this replaced fails them: there the
  regime order depended on the set alone, so carry-over was confounded with the set.

**Each trial:**
1. `ht_restore`.
2. `drop_caches`.
3. `ht_apply SET`.
4. `ht_record pre-…`.
5. Load and classify. During them, a 2 s sampler records `AnonHugePages` and `ShmemPmdMapped`.
   In (a), an `ht_record` also runs between the load and the classify.
6. `ht_record post-…`.
7. One `probe-tune {"kind":"trial",...}` line, which carries:
   - `load_s`, `classify_s`, `precompact_s` and `total_s`;
   - `teardown_s`, kept out of `total_s`: for (a) the tmpfs unmount; for (b) the process's close,
     report, unmap and exit after its classify phase;
   - the output's and the report's sha256;
   - the free fraction in 2 MiB blocks before the trial;
   - the vmstat deltas: compaction stalls and successes, and THP allocations and fallbacks.

Fragmentation is not reset between trials. The trial position is recorded, so
`probe-tune-drift.tsv` shows the state after successive loads.

**Network ceiling:** a 30 s ranged-GET discard read at 64 workers runs before the trials and
again after them. The object's bytes divided by the faster of the two rates is the load floor.

**Selection rule** (as registered; `scripts/lib/tune_tables.py`), applied per regime:
- **Valid trial:** load and classify exit 0, the set applied, and the output and report sha256
  are the run's modal ones.
- **Counted:** warm-up trials never count. Neither does any trial of a repetition that did not
  record all 12 of its trials, so a TTL kill leaves whole repetitions only and cannot favour the
  sets that ran early in the last one.
- **Cell:** a cell (regime, set) needs at least 3 valid trials.
- **Undetermined:** with 3 repetitions, a cell reaches 3 counted trials only if all three
  repetitions are complete. A TTL kill (or any lost trial) anywhere in repetition 3 therefore
  makes the probe undetermined, and so does an invalid `none` trial. The post then prints a
  `tune_tables: UNDETERMINED ...` line and exits 3. `run.sh` marks the run failed, and S3's set
  is not chosen by that run.
- **Qualifying:** a set qualifies if both of these hold:
  - its median total beats `none`'s by more than 2 × the larger of the two cells' ranges;
  - its median classify is no worse than `none`'s plus 2 × the larger classify range.
- **Pick:** the qualifying set with the lowest median total wins; otherwise `none`.

S3 takes regime (a)'s pick. Regime (b)'s pick is recorded for ours (O0b).

**Resolution, before any null:**
- The smallest gain the rule can accept is 2 × range(none).
- The load ceiling is the median load of `none` minus the floor, an upper bound on any
  load-side gain.
- If the ceiling is below the resolution, the selection table says that a `none` verdict is not
  evidence.

**Law 1:** every completed trial must write the same output and the same report, so upstream
`-M` and ours' engine agree. If they do not, the post exits 1.

**Tables** (post: `scripts/post/g3-probe-tune-x8g.24xlarge.sh`):
- `tables/probe-tune-trials.tsv`
- `probe-tune.tsv` (per regime and set)
- `probe-tune-selection.tsv`
- `probe-tune-drift.tsv`

```bash
make hosttune-test
make rehearse SPEC=runs/g3-probe-tune-x8g.24xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-tune-x8g.24xlarge.json
make orphans
```

**Rehearsal** (`scripts/lib/probe_rehearse.sh`, kind `tune`) runs the body unmodified, with
these stand-ins:
- the viral DB for RODA, its `hash.k2d` served with a real multipart ETag and copied by the
  s5cmd stub;
- SRR062634's 200k pairs for the sample;
- a fake `/sys` and `/proc` tree for the knobs.

It runs the full plan, and passes on observed output:
- 38 valid trial lines, streamed and pushed: 2 warm-up, and 3 per cell;
- one output sha256 and one report sha256 across both regimes;
- a `teardown_s` on every trial;
- 97 `ht-record` lines, streamed and pushed;
- `none` trials wrote nothing, and every other trial wrote;
- the host is back at its boot values at the end;
- `tune_tables.py` makes the tables. `make test` runs its `--self-test` on synthetic cells.

**Runtime estimate:**
- (a) is about 280 s a trial: s5cmd at about 4.75 GB/s from probe (a), about 2 s of classify
  (U1), and the unmount.
- (b) is about 345 s a trial: E2's N = 1 load of 324 s, then classify and exit.
- 19 of each (the warm-up included), plus about 15 min of setup and ceilings, comes to about
  3.5 h, about $33 at the on-demand price.
- The TTL is 360 min, with a cost_limit of $56.28 (TTL × $9.38/h): a runaway backstop, about
  1.7× the estimate. There is no budget cap (Scott, 2026-10-09, #25); the harness refuses only a
  cost_limit above TTL × price × 1.10 (docs/run.md, "cost_limit").
