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
