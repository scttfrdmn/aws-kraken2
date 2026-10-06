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
LB_LADDER=scripts/loadbench.ladder LB_PROFILE=1 make loadbench   # + attribution, + profiles
make run GATE=g2 SPEC=runs/loadbench.json        # canonical: m7g.2xlarge, us-west-2
make run GATE=g2 SPEC=runs/loadbench-g4.json     # the same on Graviton4 (c8g or r8g)
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
(`--paired`). The reads are the oracle's (`make stage-reads` or `scripts/fetch-reads.sh`).

**States** (`LB_STATES`): `cold` drops the page cache before the run: `ak2_drop_caches` on AWS,
`echo 3 > /proc/sys/vm/drop_caches` (root or `sudo -n`) on Linux, and `sudo -n purge` on macOS.
If the cache cannot be dropped (for example, no passwordless sudo on a laptop), the cold rungs
are skipped, and the manifest records `cold.available=false`. A warm run is never labelled cold.
`warm` runs right after the same implementation's cold run, so the cache then holds the database
and the reads. Without a cold state, one unrecorded priming run warms the cache first. Every
binary runs once (`--version`) before the matrix, so no rung pays for a first exec.

**Order:** input, then repetition, then implementation, then state. Implementations interleave
within each repetition, so drift over the run affects them all alike.

**Ladder** (`LB_LADDER`, Law 5): a file of `LABEL COMMIT [NAME=VALUE...]` lines. Each commit's
`cmd/aws-kraken2` is built into `.cache/loadbench/bin/<goos>-<goarch>/<commit>/` and benchmarked
as `LABEL`, with that environment (`@NCPU` is replaced by the online CPU count). Consecutive
lines form one row of the attribution table. `scripts/loadbench.ladder` is the #36 ladder.

**Profiling** (`LB_PROFILE=1`): after the matrix, on the last input, for each implementation and
state, it runs `perf stat` (Linux, when `perf` exists; `sudo -n perf` when possible) with
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

`runs/loadbench.json` (m7g.2xlarge, us-west-2) and `runs/loadbench-g4.json` (Graviton4; truffle
picks c8g or r8g) have the same body. It installs the toolchain (with `perf`), logs the THP mode,
kernel, CPU count and root volume, and clones the launch commit. It stages Standard-8 and the
SRR062634 reads with `ak2_stage` from
`s3://cookbook-942542972736-us-west-2/aws-kraken2/data/`, checking each file against its sha256
metadata. Then it builds upstream and ours and *sources* `scripts/loadbench.sh` with
`LB_LADDER=scripts/loadbench.ladder LB_PROFILE=1`, so cold rungs use `ak2_drop_caches` and each
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
