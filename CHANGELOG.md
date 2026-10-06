# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- Run harness: `make run` (`scripts/run.sh`, on-instance hygiene preamble `scripts/preamble.sh`,
  settings `scripts/ak2.env`), `make orphans`, `make report`, with runbooks `docs/run.md`,
  `docs/orphans.md`, `docs/report.md` and the spore.host brief `docs/spore-host.md` (#1).
- `internal/kdb`: `opts.k2d` (IndexOptions, legacy 48/56-byte layouts), `hash.k2d` header, and
  32/40-bit cell-width detection cross-checked against object size; `cmd/k2probe header|opts` (#3).
- G0a spec `runs/g0a.json`, post-processing `scripts/post/g0a.sh`, and its runs under
  `results/g0a/` (#3).
- Harness hardening from the law review:
  - a bucket allow-list (`AK2_DATASETS`), checked statically and on the instance by an `aws`
    PATH shim;
  - `inputs[]` refused in favour of `ak2_stage`;
  - the wrong-region launch is terminated;
  - disowned log tee and pusher;
  - Payer, TTL and cost ceilings, env-key and dirty-tree refusals;
  - a `drop_caches` probe;
  - `ak2_phase` timings and `ak2_req` request counts;
  - an all-region orphan sweep;
  - an ETag check in `scripts/post/g0a.sh`.
- Re-review fixes:
  - a finish handler that survives a process-group SIGTERM and logs the real exit status;
  - a checked log-tee start;
  - `set -e` refused in specs;
  - `ak2_req` validation;
  - `cold` markers in `phases.tsv`, with `ak2_drop_caches` fatal (exit 95) when caches can't be
    dropped;
  - placement/spot refused, an env-key allow-list, and a wider dirty-tree check;
  - in-flight phases recorded on a kill;
  - `readonly -f` on the helpers.
- Follow-ups:
  - a shell-aware errexit check (`scripts/lib/errexit_check.py`, self-tested in `make test`),
    backed by runtime `$-` checks;
  - a PIPE trap;
  - `ak2_req` bucket validation;
  - helper errors and state kept in files, so subshell errors count;
  - KILL for a hung tee;
  - shim content and self-test verification.
- `run.sh` records its post-run orphan check: `<run dir>/orphans.txt`, plus
  `manifest.orphan_check` (rc, own_gone, other live instances with flags, regions checked and
  failed). `make report` shows it as a row.
- Orphan check scoped per run:
  - `run.sh` now runs `scripts/orphans.sh --own <task_id> <instance_id>`, which fails only if
    its own instance survives;
  - concurrent runs' instances are listed as informational;
  - instances past their `spawn:ttl-deadline` + 15 min are flagged as probable orphans;
  - `make orphans` stays global and strict, for when no runs are in flight.
- Pin identity is the commit SHA: every manifest writer (`run.sh`, `oracle.sh`, `g0b.sh`,
  `equiv-seqout.sh`, `classify-oracle.sh`, `harness-build.sh`) records the full upstream SHA and
  its `git describe --tags`, computed by `scripts/pin-identity.sh` from `scripts/pin.env` and
  the oracle source checkout.
- `make tag-objects` (`scripts/tag-objects.sh`, `docs/tag-objects.md`): `project=aws-kraken2`
  plus `kind=data|payload|results` on every object under the project prefix. `stage-db.sh`,
  `stage-reads.sh` and `run.sh` tag at write time, and `run.sh` tags the run prefix after each
  run (the instance role cannot tag). The first run tagged 134 objects.
- spawn 0.123.0: `scripts/udsize` is bumped to v0.123.0. The user-data builders were re-read
  (only the bootstrap's #707 `$-` announcement changed).
- User data:
  - `command[2]` is now `scripts/stub.sh` (region assert, presigned GET, sha256 check, exec);
    the preamble and body travel as `<run prefix>/payload.sh`;
  - `run.sh` measures the exact user data with spawn v0.121.0's builders (`scripts/udsize`)
    and refuses within 1024 bytes of EC2's 16384-byte cap, including under `DRY_RUN`.
- `internal/chash`: port of upstream's compact hash lookup path (fmix64, 32- and 40-bit cells, linear and double probing, RAM and mmap loaders, `CellSource` probe over `io.ReaderAt`); `upstream/chash_dump.cc` and `upstream/chash_keys.cc` oracle harnesses; `k2probe equiv-hash`; `make harness` and `make g0b` (#4).
- `internal/mmscan`: port of upstream's `MinimizerScanner` (DNA and protein, both revcom versions,
  `LoadSequence` intervals, zero allocations per minimizer). It is checked against upstream by
  `upstream/mm_dump.cc`, `k2probe equiv-scan` and `make g0b PART=scan`. `scripts/harness-build.sh`
  builds the oracle harnesses (#5).
- `internal/taxo`: `taxo.k2d` reader ported from upstream `taxonomy.{h,cc}` (node fields, names,
  ranks, external-ID map, `IsAAncestorOfB`, `LowestCommonAncestor`, the `taxo.Tree` interface),
  checked against upstream's own `Taxonomy` class via `upstream/taxo_dump.cc` (#11).
- `internal/report`: kraken-style `--report` and `--use-mpa-style` ported from upstream
  `reports.{h,cc}`, including `--report-zero-counts` and libstdc++'s `std::sort` tie order for
  siblings; byte-identical to upstream's reports on real reads (#15).
- `scripts/harness-build.sh`: builds `upstream/<name>.cc` oracle harnesses against the pinned
  sources with upstream's compiler flags.
- `internal/seqio` (FASTA/FASTQ reader ported from upstream `fast_reader`, two-file and interleaved
  pairs, gzip/bzip2 input with the wrapper's detection and `gzip -dc`'s behaviour on damaged
  streams, quality masking with Linux aarch64 unsigned-char semantics) and `internal/seqout`
  (`--classified-out`/`--unclassified-out` writers; `seqout.Ordered` restores batch order in the
  seqout oracle test, while the CLI orders its output with its own pwrite sequencer). `make equiv-seqout`
  checks both byte-for-byte against upstream on Viral (#12, #16).
- `internal/classify`: per-read classification (ClassifySequence's minimizer loop, ResolveTree,
  `--quick`, `--confidence`, `--minimum-hit-groups`, `-F`) and the `--output` line (#13, #14), with
  the `upstream/classify_trace.cc` oracle harness, `make harness` and `make oracle-classify`.
- `cmd/aws-kraken2`: the classifier CLI. Its command line is upstream's `kraken2` wrapper's
  (Getopt::Long parsing, defaults, `find_db`, validation, messages, exit statuses, compression
  auto-detect), followed by classify's own checks and run: a sequential block reader, N workers
  with per-worker buffers and counters, output written in input order by pwrite at prefix-sum
  offsets, and the report from merged counters. `--report-minimizer-data` (#18) and
  translated-search databases are refused.
- `make oracle` (#17, `scripts/oracle.sh`, `docs/oracle.md`): upstream's `kraken2` vs
  `bin/aws-kraken2` on real reads (SRR062634, ERR478965, SRR28305653 and awk variants for `/1`
  `/2` IDs, mates shorter than k and unequal mate files) against Viral and/or Standard-8. It
  byte-compares `--output`, `--report`, the sequence outputs, stdout and the exit status, runs
  coverage checks, negative controls and matrix-integrity checks (requested outputs exist,
  nothing unrequested is written, every case recorded, a filter must match), covers standard
  output, FASTA, bzip2, `KRAKEN2_DB_PATH`/`KRAKEN2_NUM_THREADS` and unwritable outputs, and
  writes `results/g1/oracle-<db>-<ts>/`
  (`manifest.json`, `cases.tsv`, `checks.tsv`, `summary.md`).
- CI (#20): `.github/workflows/ci.yml` runs build, test and `go test -race ./...` (oracle-backed
  tests required, `AWS_KRAKEN2_REQUIRE_ORACLE=1`, with `AWS_KRAKEN2_DBS` naming the databases
  the job provides), lint with a pinned staticcheck, and `make oracle DB=viral` on
  `ubuntu-24.04-arm`. The `.oracle` cache key includes the compiler version.
- `runs/g1-oracle.json`: TaskSpec for `make oracle DB=all` on Graviton in us-west-2, the
  canonical evidence for both databases. Prepared, not launched. `make stage-db`
  (`scripts/stage-db.sh`) and `make stage-reads` (`scripts/stage-reads.sh`) make the in-region
  database and read copies it stages and verifies, so the run depends on neither genome-idx nor
  ENA. Setup steps fail fast; the oracle streams into the run log; only this run's result
  directories are pushed, and push failures count into the exit status.
- `classify.Calls`: report input from merged counters, keeping zero-read taxa, with an end-to-end
  counters-to-report test.
- `upstream/chash_build.cc` and a g0b `hash` sub-step: a synthetic 40-bit table built by
  upstream's own `CompareAndSet`/`WriteTable` (linear and double-hashing builds), looked up by
  upstream and by `internal/chash`, so the 40-bit cell path is checked against upstream.
- `docs/harness.md` runbook; `scripts/cxx.sh` is the compiler choice shared by the upstream build
  and the harnesses.
- `make bracken-check` (#19, `scripts/bracken-check.sh`, `docs/bracken-check.md`): runs Bracken
  v3.1 (`est_abundance.py`, levels S and G, `-r 100`) on upstream's and our `--report` for
  Standard-8 on ERR478965 and SRR062634, and byte-compares the reports, Bracken's tables, its
  adjusted reports and its stdout. Writes `results/g1/bracken-<ts>-<sha>/`.
- `make loadbench` (#36, `scripts/loadbench.sh`, `docs/loadbench.md`): load-path and
  whole-process wall time of upstream and ours (plus a per-change ladder of our builds) on one DB
  and thread count, cold and warm, with an optional perf/pprof profiling mode; TaskSpecs
  `runs/loadbench.json` (m7g.2xlarge) and `runs/loadbench-g4.json` (Graviton4). `aws-kraken2`
  writes a per-phase timing log with `AK2_TIMINGS=1` and a CPU profile with `AK2_CPUPROFILE`
  (the default stderr is unchanged). `chash.LoadFrom` with a `Filler` interface (`ParallelPread`)
  fills the table buffer, so a later S3 ranged-GET loader can fill the same buffer.
- G0c (#7, #8): `make g0c PART=local|probes|runs` (`scripts/g0c.sh`, `docs/g0c.md`, specs
  `runs/g0c-{runs,probes}.json`, post scripts `scripts/post/g0c-{runs,probes}.sh`).
  `internal/runlen` measures the occupied-run structure of a hash.k2d with parallel chunk scans,
  an in-order merge, and a brute-force reference: the run histogram (wrap run joined), the
  longest run, the overlap tail per shard count, and Borel theory. `internal/rangeread` is an
  in-order streaming reader over parallel ranged reads (file, or anonymous HTTPS with If-Match).
  `k2probe runs` does one pass, SHA-256 included, and `k2probe probes` samples classify's
  lookups from real reads and resolves them with point GETs through `chash.Probe`.
  `make stage-reads` now also stages ERR598966.
- `make sortfuzz [SORTFUZZ=quick|full]` (`scripts/sortfuzz.sh`, `docs/sortfuzz.md`): a
  differential fuzz of `internal/report`'s `stdSort` against libstdc++'s `std::sort`
  (`upstream/sortfuzz.cc`, `internal/report/sortfuzz_test.go`) with upstream's report comparator.
  The full corpus has about 10^6 heavy-tie cases, every n from 0 to 2048, and McIlroy
  median-of-3 killers. Each case reports whether the heapsort fallback ran, detected by a
  `std::__partial_sort` specialization on the harness's own iterator type. A CI job runs the full
  corpus in `amazonlinux:2023` (GCC 11.5.0) (#35).

### Changed

- Classification speed (#39, #36). `mmscan.Scanner.AppendMinimizers` runs the scanner loop over
  a whole sequence with its state in locals, and `classify.Tokens.Scan` uses it, with
  MurmurHash3 called directly for the capped-database check. Its output is held to `Next`'s by
  a test, and keeps the reverse complement incrementally. The second mate's block is sized like
  the first's. (`seqio.Recycle`, block reuse, was measured and reverted: no gain.) `chash.GetBatch` resolves a read's lookups with their cache misses
  overlapped. It returns the same values as `Get`, checked by a test and by `k2probe equiv-hash`
  against upstream. `AK2_MEMPROFILE` writes an allocs profile.
- `make loadbench`:
  - the implementation order rotates per repetition;
  - the manifest records the database's storage (device, model, EBS volume);
  - the summary states the cold load rate and shows ranges in the attribution table;
  - a per-cell noise floor from A/A control rungs (same binary, consecutive in the ladder):
    the larger of their largest |Δ median| and half their median range width, with the number
    of pairs stated;
  - one verdict rule for attribution rows and the per-cell acceptance table against upstream:
    within noise (below floor), above floor with ranges overlapping, or ranges separated;
  - `LB_REPS_COLD` / `LB_REPS_WARM` set per-state repetitions;
  - `LB_WARMUP` / `LB_WARMUPS` add unrecorded cold warm-up runs, kept in the manifest;
  - `LB_READS`, `LB_PROFILE_IMPLS` and `HEAD` in the ladder are new;
  - `runs/loadbench-g4.json` uses instance-store NVMe (r8gd/c8gd).
- One `cmd/k2probe` dispatcher, with commands registered from `init()`. `header`/`opts` moved
  into their own files, and `equiv-scan` reads `opts.k2d` through `internal/kdb`.
- `scripts/harness-build.sh [-v lp|dh|lp,dh] [name...]` is one interface for every caller:
  - flags and LDFLAGS are read from upstream's Makefile, and it fails without `-DLINEAR_PROBING`;
  - it keeps one archive per variant, keyed by pin, compiler, flags and sources, and refuses a
    modified upstream tree;
  - binaries go under `.oracle/harness/<pin>/`, with a `.BUILD` record per binary.
- Shared `.oracle`/`.cache` resolve only through git's common dir. Scripts use
  `scripts/paths.sh`, tests use `internal/oracletest`, and `oracle-build.sh`, `fetch-db.sh`
  and `fetch-reads.sh` now use it too. `oracletest` reads the pin from `scripts/pin.env`, and
  `AWS_KRAKEN2_REQUIRE_ORACLE=1` turns skips into failures.
- `scripts/g0b.sh hash|scan|all`:
  - one `G0B` variable (`PART` accepted);
  - run IDs are UTC time plus short sha, and an existing results dir is refused;
  - a manifest per step, with the DB ETag inline;
  - a missing DB, read set or key population, or zero comparisons, now fails the run.
- `fetch-db.sh` falls back to HTTPS when the AWS CLI is absent.
- Dedupe: `internal/classify` uses `chash.MurmurHash3` and `seqio.MaskLowQuality` (unsigned),
  and its own copies are gone.

### Fixed

- `chash.Load` (#36): the table is 2 MiB-aligned and advised `MADV_HUGEPAGE`, as in upstream's
  LoadTable. Under THP mode `madvise` (Amazon Linux 2023's default) it was on 4 KiB pages, which
  meant one fault per 4 KiB at load and as many PTEs to tear down at exit.
- `aws-kraken2`: an unwritable `--report` is silently not written and the run exits 0, as with
  upstream's unchecked ofstream (it exited 1). "Unable to open file" reasons are worded as C's
  strerror.
- `fetch-reads.sh` uses `sha256sum` when `shasum` is absent and fails on an empty hash. It retries
  ENA requests (the portal API with `--retry-all-errors`; the FASTQ stream with `--retry`, plus a
  retry of the whole pipeline) and fails loudly when the retries run out.
- CI uploads only the result directories the run created, not the committed ones, in an
  artifact named for the PR head commit.
- Oracle-backed tests no longer call `t.Skip` directly: they skip through `oracletest`, so
  `AWS_KRAKEN2_REQUIRE_ORACLE=1` fails them. Every one of them runs in CI against Viral: the
  classify traces come from `scripts/classify-oracle.sh`, and the seqio/seqout oracles from
  `make equiv-seqout` (via `.cache/equiv-seqout/latest`). CI prints a ran/skipped summary of
  `go test -race -v ./...`.
- `fetch-reads.sh` checks FASTQ structure, and retries the FASTQ stream as a whole pipeline
  rather than with curl `--retry`. `stage-reads.sh` and the G1 spec check that each gzip copy
  decompresses to the FASTQ its SOURCE names. The spec stages only the declared read files.

- `internal/chash`: `32 + capacity × cellBytes` is checked for overflow, so a crafted header can
  no longer pass the size check into an out-of-bounds slice. The header is decoded by
  `internal/kdb` and the file size checked with `kdb.CellWidth`. `ReaderAtSource` accepts a full
  read returned with `io.EOF`.
- `internal/mmscan` golden tests fail, rather than skip, when a golden stream is missing.
- `internal/report` oracle: each resolution control must fire at least once per database.
  `stdsort.go` carries a provenance note (libstdc++ `stl_algo.h`/`stl_heap.h`, HP 1994 / SGI 1996
  STL).
