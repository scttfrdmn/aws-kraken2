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
| (g) rapidgzip crash | `runs/g3-probe-rgcrash-r8g.16xlarge.json` (`scripts/g3/probe-rgcrash.body.sh`) | 1 × r8g.16xlarge | the identity step's `rapidgzip -d -c -P K FILE \| sha256sum`, 0.14.5 and 0.16.0, on the c10 files for 95 min, with core capture and gdb ("The rapidgzip crash probe" below) |
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

**What it does:**
1. **Setup.** dnf installs gdb and zstd. `dnf debuginfo-install` fetches python3, glibc and
   libstdc++ debuginfo; this is best effort and recorded. The wheels' `.so` carry only the symbols
   they ship with.
2. **Two rapidgzip versions.** 0.14.5 comes from lever.sh's `lv__rg_ensure` (pip
   `--require-hashes`). 0.16.0, the latest, is installed the same way in its own venv, pinned to
   the sha256 of its cp39 manylinux aarch64 wheel (`RG16_HASH` in the body, from PyPI's JSON API).
   Each version's `tool` line records the wheel, the wheel sha256, the `.so` and its sha256.
   Each version's `.so`, its python and libpython go to `out/bundle-<version>.tar.zst`, so a core
   can be opened offline.
3. **Core capture.** `ulimit -c unlimited` is set, and `kernel.core_pattern` is set to
   `/dev/shm/cores/core.%p.%e.%t`; the previous value is recorded and restored at the end. A
   positive control follows: the same python SIGSEGVs itself, and the run continues only if a
   core appears and gdb reads frames from it (the `core-control` line). Without that control,
   "no core" would not be evidence of anything.
4. **Inputs.** The c10 cohort's 20 gz files (`runs.tsv` ranks 1 to 10, 10.6 GB) go to
   `/dev/shm`, each checked against its sha256 metadata. GNU `gzip -dc | sha256sum` runs once per
   file, 8 at a time, to give the reference.
5. **The loop.** It starts once page-cache state is logged (`meminfo` lines; this is not a
   timing probe, so there is no drop_caches) and runs until 95 min after the body starts, which
   is at least 25 min before the 120 min TTL. It runs 8 lanes, mirroring the identity step's
   command: `rapidgzip -d -c -P K FILE | sha256sum`.
   - Versions alternate job by job within a lane, so about half the jobs run each version at any
     time.
   - Every fourth job of a lane runs at `-P 16`; the rest run at `-P 8`.
   - Files go round-robin.
   - Each job has a 300 s timeout that sends SIGABRT, so a hang also leaves a core.
6. **On any failure** (a non-zero exit or a wrong sha256):
   - its stderr and the matching dmesg lines are recorded;
   - gdb runs on its core (`info sharedlibrary`, `p $_siginfo`, `bt`, `thread apply all bt`,
     `info registers`, `x/16i $pc`);
   - the first 6 cores are zstd-compressed and pushed;
   - the loop carries on.
7. **Tally.** The tally and the jsonl are pushed every 100 jobs and after every failure.

**Lines** (streamed as `probe-rgcrash {json}` and in `out/rgcrash.jsonl`):

| kind | what it records |
|---|---|
| `tool` | one per version: wheel, sha256s, `.so`, python |
| `host` | gdb, debuginfo result, kernel, CPU, nproc, glibc |
| `core-control` | the previous and new core_pattern, ulimits, the control's core and gdb frame count, `ok` |
| `reference` | 20 lines: the GNU gzip sha256, exit and seconds per file |
| `meminfo` | after-fetch, loop-start, every 5 min, end |
| `job` | one per job: `n`, `lane`, `version`, `file`, `P`, `exit`, `signal`, `timeout`, `sha256`, `match` (against the reference), `seconds`, `pid` |
| `failure` | one per failed job: `core`, `core_bytes`, `core_pushed` (its out/ key, or null after the first 6), `gdb_frames`, `fault` (si_addr), `stderr`, `dmesg` |
| `summary` | one per version: `jobs`, `P8`, `P16`, `crashes` (any signal), `sigsegv`, `timeouts`, `nonzero_exit`, `wrong_sha`, `wrong_sha_exit0`, `crash_rate`, `seconds` |
| `restore` | core_pattern back to its previous value (`restored`) |

gdb's output also streams as `rgcrash-gdb <n> | ...` lines in the run log, and is pushed as
`out/gdb/<n>.txt`. Cores are pushed as `out/cores/core.<pid>.<comm>.<t>-job<n>-<version>.zst`.

**Files** (in the run's `out/`):
- `rgcrash.jsonl`;
- `rgcrash-tally.tsv`: version × P, with jobs, nonzero_exit, crashes, timeouts and wrong_sha;
- `gdb/`, `cores/`;
- `bundle-0.14.5.tar.zst`, `bundle-0.16.0.tar.zst`.

**How to read it:**
- **Reproduced:** a `summary` line with `crashes` > 0. The `failure` lines and `gdb/<n>.txt` hold
  the backtrace. The faulting thread is the one gdb shows first, in `bt`.
- **Opening a core offline:** on AL2023 aarch64, unpack the version's bundle and run
  `gdb <python> <core>` with `set solib-search-path` pointing at the unpacked `.so`.
- **A `wrong_sha_exit0` above 0** means wrong output with a clean exit. That is worse than a
  crash, because the identity step catches it only through the sha256.
- **No crash is not evidence of no defect.** At the c10 rate (2 in about 1,553, about 1.3e-3 per
  decompression), N jobs of one version see no crash with probability exp(−1.3e-3 × N): about
  0.05 at N = 2,300. Check each version's `jobs` against that before calling a version clean.
  The ladder's identity lanes also ran GNU gzip beside rapidgzip, and that load is not reproduced
  here.

**Cost:** TTL 120 min, `cost_limit` = TTL × the on-demand price ($3.77024/h: $7.55, from
`scripts/g3/mkspec-u.sh probe-rgcrash r8g.16xlarge 120 scripts/g3/probe-rgcrash.body.sh us-west-2b`).

**Rehearsal** (`scripts/lib/rgcrash_rehearse.sh`, through `probe_rehearse.sh`): the body runs
unmodified in an AL2023 aarch64 container on the rootful podman VM. The container is privileged,
because core_pattern is the VM kernel's. It runs as ec2-user under `bash -e -c`, after the probe
helpers' stand-ins.
- **Real:** dnf, gdb, the debuginfo install, both pip `--require-hashes` installs from PyPI, sysctl
  and the cores.
- **Stand-ins:** the stub aws over a directory is S3. The c10 names hold the small real read sets
  from `.cache/reads`.
- **The induced crashes:** with a 150 s loop (`AK2_REHEARSE_LOOP_S`), the host sends SIGSEGV to
  3 running rapidgzip processes (0.14.5, 0.16.0, 0.14.5), with `AK2_REHEARSE_MAXCORES=2`.

It passes on observed output:
- the tool lines carry the pinned wheel sha256s;
- the core control is ok;
- the job lines streamed equal the pushed ones;
- exactly the killed jobs fail with exit 139, and each has a core, gdb frames, and gdb output
  streamed and pushed;
- 2 valid zstd cores are pushed;
- every other job matches the reference;
- the tally and the summaries add up;
- the VM's core_pattern after the run equals its value before.

A kill that lands after the last write leaves a correct sha256, so the check uses the exit status
only.

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
