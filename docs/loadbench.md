# make loadbench

**What:** measures the load path and the whole-process wall time of upstream `kraken2` at the
pin and of `bin/aws-kraken2` (and, optionally, a ladder of earlier builds of ours, one per change)
on one database and thread count, with a cold and a warm page cache (issue #36). It times every
run of every implementation with the same instrument (`scripts/lib/lbrun.py`), so the numbers
compare like with like. Backed by `scripts/loadbench.sh`, `scripts/lib/lbrun.py`,
`scripts/lib/lbsummary.py` and `scripts/loadbench.ladder`.

```bash
make loadbench                                   # Standard-8, 8 threads, 3 reps, cold + warm
make loadbench DB=viral THREADS=4 REPS=5
LB_REPS_COLD=3 LB_REPS_WARM=10 make loadbench    # per-state repetitions (the AWS specs use these)
LB_LADDER=scripts/loadbench.ladder LB_PROFILE=1 make loadbench   # + attribution, + profiles
make run GATE=g2 SPEC=runs/loadbench.json        # canonical: m7g.2xlarge, us-west-2
make run GATE=g2 SPEC=runs/loadbench-g4.json     # Graviton4 with instance-store NVMe (r8gd/c8gd)
```

## What is measured

Each run is one classifier process, with stdout discarded and `--output` written to a scratch
file. `lbrun.py` takes `t0` immediately before the fork, reads stderr as it arrives, and records:

| column | meaning |
|---|---|
| `wall_s` | exec to exit |
| `load_s` | exec to the arrival of `Loading database information... done.`: process startup (including upstream's Perl wrapper), then the `opts.k2d`, `taxo.k2d` and `hash.k2d` loads |
| `classify_s` | the `processed in X s` figure the classifier prints itself |
| `tail_s` | that line's arrival to exit: report, final flushes, teardown (unmapping the table) |
| `minflt`, `majflt`, `user_s`, `sys_s`, `maxrss` | `getrusage(RUSAGE_CHILDREN)` over the run (the whole process tree) |
| `thp_fault_alloc`, `thp_fault_fallback` | `/proc/vmstat` deltas over the run (Linux): huge pages the faults got, and fallbacks to base pages |
| `output_sha256` | of `--output`; the summary checks that all implementations agree (Law 1 itself is `make oracle`'s) |

Both classifiers write stderr unbuffered, so a line's arrival time is its write time.

Ours also runs with `AK2_TIMINGS=1`, which makes it write one `ak2-timing` line per phase to
stderr: `opts`, `taxo`, `hash`, `setup`, `classify`, `close`, `report`, `unmap` and `total`, with
start, duration and getrusage deltas (fault counts, user and sys time). These go to
`timings.tsv`. With the variable unset (the default), stderr is byte-for-byte upstream's format.
`AK2_CPUPROFILE=<file>` writes a pprof CPU profile of the whole run.

**Inputs** (`LB_INPUTS`, cheapest first): `empty` is a zero-byte FASTQ, so the run is startup,
load and teardown only. `se` is SRR062634 mate 1 (200 000 reads). `pe` is SRR062634 paired
(`--paired`). The reads are the oracle's (`make stage-reads` or `scripts/fetch-reads.sh`), from
`.cache/reads` unless `LB_READS` names another directory.

**States** (`LB_STATES`): `cold` drops the page cache before the run: `ak2_drop_caches` on AWS,
`echo 3 > /proc/sys/vm/drop_caches` (root or `sudo -n`) on Linux, and `sudo -n purge` on macOS.
If the cache cannot be dropped (for example, no passwordless sudo on a laptop), the cold rungs
are skipped, and the manifest records `cold.available=false`. A warm run is never labelled cold.
`warm` runs right after the same implementation's cold run, so the cache then holds the database
and the reads. Without a cold state, one unrecorded priming run warms the cache first. Every
binary runs once (`--version`) before the matrix, so no rung pays for a first exec.

**Warm-up** (`LB_WARMUP`, default 1): before the matrix, one cold run of the first implementation
on the first input, not counted in any cell. The first cold read of a freshly staged database
was an outlier on both boxes (upstream empty cold: 6.791 s against 7.5 s on r8gd's NVMe, 61.7 s
against 60.4 s on m7g's gp3), so the matrix starts after it. Its numbers are in the manifest
(`warmup`) and in `summary.md`.

**Repetitions:** `LB_REPS` for both states, or `LB_REPS_COLD` and `LB_REPS_WARM` separately.
Warm cells are sub-second, so the AWS specs run 10 of them; cold cells take a minute each on
EBS, so they run 3. The thread count is fixed (`LB_THREADS`, 8 in the specs = the boxes' vCPUs)
and is the same for both implementations.

**Order:** input, then repetition, then implementation, then state. The implementation order
rotates by one each repetition (repetition r starts with the implementation at position r−1),
so no implementation always runs first, or always right after the same neighbour. With 3
repetitions and more than 3 implementations, not every position is covered; drift that is
slow next to one repetition still lands on all implementations alike.

**Storage caps cold rungs.** A cold rung reads all of `hash.k2d` from the device, so its load
time is at least size ÷ device throughput, the same for every implementation. On an EBS gp3
root volume at its baseline (125 MiB/s), Standard-8's 8 GB takes about 60 s, and every cold
rung on m7g.2xlarge measured 126–127 MiB/s: those cold rungs can resolve teardown and
classification differences, but not a difference in the load itself. `summary.md` computes
this rate (hash bytes ÷ median cold load) and says when all implementations agree within 5%.
The manifest records where the database lives (`db.storage`: device, filesystem, disk model and
serial, and, for EBS, the volume type, IOPS and throughput when the instance may describe it).
For cold numbers that measure the load path, use instance-store NVMe (Law 2), as
`runs/loadbench-g4.json` does.

**Ladder** (`LB_LADDER`, Law 5): a file of `LABEL COMMIT [NAME=VALUE...]` lines (`COMMIT` may
be `HEAD`). Each commit's
`cmd/aws-kraken2` is built into `.cache/loadbench/bin/<goos>-<goarch>/<commit>/` and benchmarked
as `LABEL`, with that environment (`@NCPU` is replaced by the online CPU count). Consecutive
lines form one row of the attribution table: median [min–max] before and after, and the
difference of the medians.

**Noise floor.** Two consecutive ladder lines with the same binary and environment are an A/A
control (`final` → `final-aa` in the #36 ladder). A cell's noise floor is the largest
|Δ median wall| over its control pairs, and any difference at or below it, in an attribution row
or against upstream, is marked "within noise". Without a control pair the summary says so and
falls back to overlapping min–max ranges, which is lax at n = 3. The acceptance table gives each
cell one verdict for `final` (or the last ladder line) against upstream:
"≤ upstream (ranges separated)" (ours' max below upstream's min, and the difference above the
floor), "≤ upstream by median, within noise", "> upstream by median, within noise", or
"> upstream".
`scripts/loadbench.ladder` is the #36/#39 ladder. Pread streams are 8 for both implementations;
a streams change would apply to upstream too (`K2_DB_READ_THREADS`).

**Profiling** (`LB_PROFILE=1`): after the matrix, on the last input, for each implementation
(or only those in `LB_PROFILE_IMPLS`) and state, it runs `perf stat` (Linux, when `perf` exists; `sudo -n perf` when possible) with
`task-clock`, `page-faults`, `minor-faults`, `major-faults`, `context-switches`, `cpu-migrations`
and `dTLB-load-misses`. For ours it also runs `AK2_CPUPROFILE` with `GODEBUG=gctrace=1` (the
`pprof -top` text is written as well when `go` is on PATH). None of these runs count toward the
timed numbers.

## Outputs

`results/<gate>/loadbench-<db>-t<threads>-<UTC timestamp>/` (`LB_GATE`, default `g2`):
- `manifest.json`: commit and dirty flag, the upstream pin and `git describe`, and each
  implementation's label, source commit, binary sha256 and environment. Also the Go version, the
  database files and `SOURCE`, the reads' `SOURCE`, threads, reps, inputs, and the states
  requested and run. It records cold availability and method, the host (OS, kernel, model, CPUs,
  memory, page size, THP `enabled` and `defrag`), the `make run` run id when there is one,
  start/stop times and the failure count. `host.canonical_platform` is true only for Linux
  aarch64 under `make run`;
- `runs.tsv` (one row per run), `timings.tsv`, `summary.tsv` (median, min and max per input,
  state and implementation), `summary.md` (the same as tables; ours minus upstream; the
  attribution table, one row per ladder step);
- `stderr/<rep>-<impl>-<input>-<state>.txt`, and `profile/` with `LB_PROFILE=1`.

Every number in `summary.*` is computed from `runs.tsv`. When the script is sourced by an AWS
spec body, `runs.tsv` is pushed after every rung, and the whole directory at the end, to
`<run prefix>/out/<result dir name>/`.

## On AWS

`runs/loadbench.json` (m7g.2xlarge, us-west-2; database on the EBS root volume, so cold rungs
are disk-capped) and `runs/loadbench-g4.json` (Graviton4 with instance-store NVMe; truffle picks
r8gd or c8gd) have the same body. It installs the toolchain (with `perf`), and logs the THP
mode, kernel, CPU count and disks. If an instance-store NVMe device exists, it formats it (xfs),
mounts it at `/mnt/nvme` (mode 1777) and stages there; otherwise it stages into the checkout's
`.cache`. It clones the launch commit and stages Standard-8 and the SRR062634 reads with
`ak2_stage` from
`s3://cookbook-942542972736-us-west-2/aws-kraken2/data/`, checking each file against its sha256
metadata. Then it builds upstream and ours and *sources* `scripts/loadbench.sh` with
`LB_DB`/`LB_READS` pointing at the staged copies,
`LB_LADDER=scripts/loadbench.ladder LB_PROFILE=1 LB_PROFILE_IMPLS="upstream base final"`, so cold rungs use `ak2_drop_caches` and each
rung is an `ak2_phase` (so `tables/phases.tsv` shows which were cold). The ladder's commits must
be on GitHub, because the instance clones from there.

```bash
make run GATE=g2 SPEC=runs/loadbench.json DRY_RUN=1   # validate + plan, launch nothing
make run GATE=g2 SPEC=runs/loadbench.json
make orphans
```

## Failure looks like

- `loadbench: ... missing`: stage the database or reads first (`docs/oracle.md`).
- `cold rungs skipped` on stderr, and `cold.available=false`: there is no way to drop the cache
  here. Only warm numbers exist.
- `loadbench: <tag> exited N`, or `Runs with a non-zero exit` in `summary.md`: see
  `stderr/<tag>.txt`.
- `--output DIFFERS` in `summary.md` (and a non-zero exit): implementations disagreed on an
  input. Run `make oracle`.
- Exit 95 on AWS: `ak2_drop_caches` failed, so the run stopped before a rung it would have
  labelled cold.
