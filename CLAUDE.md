# CLAUDE.md — aws-kraken2

This is an experiment, not a product. Build only what the measurements need.

**The question:** How much performance and $/result does stock kraken2 leave unused on AWS on
real science workloads, and which levers account for it?

The motivating measurement is `scientific-codes-cookbook/measurements/lith-kraken2-roda/README.md`.
Its numbers *and* its process failures apply here.

## Laws

1. **Oracle.** For the same database, options and input, `--output`, `--report` and the
   classified/unclassified outputs must be byte-identical to upstream at the pin. Any difference
   is a defect.
2. **Baseline.** Compare against upstream at its best: NVMe with a tuned thread count, plus a
   big-RAM single node with the table resident. Report cold and warm runs.
3. **Real workloads.** Headline numbers come only from real public samples against real
   databases. Synthetic data is allowed in unit tests only.
4. **Hygiene.**
   - Stream logs off the instance as the run goes.
   - Use `set +e` explicitly and echo `$-` into the log.
   - Assert the instance region equals the bucket region before any I/O, and check the bucket's
     Payer.
   - Run `drop_caches` before every cold rung.
   - Run the cheapest rung first.
   - Before trusting a null result, check that the probe could have resolved the effect.
5. **Per-lever attribution.** Never report a single multiplier alone.
6. **Authority.** Scott decides scope, names, versions, releases, and when anything is done.
   Report state and outcome only.

## Fixed decisions

- Go (current stable), no cgo in the core path. Module `github.com/scttfrdmn/aws-kraken2`.
- MIT. Ported files keep Derrick Wood's notice and carry a header naming the upstream source
  file and the pinned commit (template below).
- SemVer 2.0.0, but never create tags or releases and never choose version numbers.
- CHANGELOG follows Keep a Changelog 1.1.0; only `[Unreleased]` until Scott says otherwise.
- **Upstream pin:** `DerrickWood/kraken2` @ `2731b35f7abb26ec926517274f3d87e78d42fd76`
  (2026-10-01; `git describe` = `2.17.2-20-g2731b35`; the upstream tag has no `v`). Oracle
  *and* baseline. Defined once in `scripts/pin.env`. **Pin identity is the commit SHA**: every
  manifest records the full SHA and `git describe`. The `VERSION` file's `2.17.1` is not the
  identity.
- Oracle and baseline are built from source at the pin, and go into the shared AMI when that
  lever lands. The aarch.bio kraken2 image (2.17.1) is not used for either.
- All AWS runs go through spore.host (`spawn`, `truffle`, `lagotto`, `spored`, `cohort`), via
  `make run`. Every run has a TTL and a `cost_limit`, and `make orphans` afterwards (nf-spawn#96).
- Containers come from aarch.bio, pinned by digest, with a flat `/tmp` layout (spawn#555).
- AWS account: `AWS_PROFILE=aws`.

## Format facts (verified at the pin)

- `hash.k2d` starts with four `size_t`: capacity, size, key_bits, value_bits. Then come
  `capacity` cells, each holding the value in its low bits and the compacted key in its high bits.
  Cells are 32-bit (`CompactHashCell`) or 40-bit (`CompactHashCell40`). Detect the width from
  key_bits+value_bits and from the file size, and fail loudly on anything else.
- Hash: MurmurHash3 fmix64. Compacted key = `hc >> (64 − key_bits)`. Home slot =
  `hc % capacity`.
- **Probing is linear.** Upstream builds with `-DLINEAR_PROBING` (`src/Makefile:4`,
  `CMakeLists.txt:13`), so `second_hash()` returns 1 and probe chains are contiguous runs of
  occupied cells. Probing stops at an empty cell, a key match, or a full wrap. Both pinned DBs
  were measured to be linear-probed (#4). An earlier statement that probing is double hashing
  was wrong.
- Capped DBs: skip any minimizer whose hash is below `minimum_acceptable_hash_value`.
- `opts.k2d` comes in 48-, 56- and 64-byte layouts. RODA v205's is 56 bytes (v2.0.8–2.0.9).
- Load factor is about 0.7.

## Engine

- The sharded resident table. N = 1 is a single big-RAM node.
- Each of N nodes loads its contiguous slot range, **plus an overlap tail** at least as long as
  the longest occupied run in the table, with wraparound at the end, using parallel ranged GETs.
  A probe never leaves its shard. The tail size comes from G0c's run-length measurement.
- Each node scans its own reads and routes `(slot, key, read, pos)` to the shard owning the home
  slot. Results return to the read's home node, which runs the ported classification.
- Each sample's output is one S3 multipart upload, with part numbers in read order. Reports are
  a sum-reduce. No global locks.

## Planning lives on GitHub, not here

Project, milestones G0–G3 and issues on `github.com/scttfrdmn/aws-kraken2`. Allowed local files:
README, LICENSE, CHANGELOG, CLAUDE.md, code, tests, scripts, `docs/` (process runbooks only),
`runs/` (checked-in TaskSpecs) and `results/`. **No plan, status or TODO files.**

## Process: documented and mechanized

Every repeatable process is a `make` target backed by `scripts/`, with a runbook in `docs/`.
If anything is done by hand twice, mechanize it before the third time. Subagents use the
targets; ad hoc commands only during exploration.

| target | runbook |
|---|---|
| `make build` / `make test` / `make lint` | [docs/build.md](docs/build.md) |
| `make oracle [DB=viral\|standard8\|all]` / `make stage-db DB=…` / `make stage-reads` | [docs/oracle.md](docs/oracle.md) |
| `make decomp-shim TOOL=gnu\|pigz\|rapidgzip DIR=…` (a `gzip` shim for `DECOMP_BIN`; ours' `AK2_DECOMPRESS=pipe`) | [docs/oracle.md](docs/oracle.md) ("Decompressor shims") |
| `make harness [NAME=…] [VARIANTS=…]` | [docs/harness.md](docs/harness.md) |
| `make g0b [G0B=hash\|scan\|all]` | [docs/g0b.md](docs/g0b.md) |
| `make g0c [PART=local\|runs\|probes]` | [docs/g0c.md](docs/g0c.md) |
| `make equiv-seqout` | [docs/equiv-seqout.md](docs/equiv-seqout.md) |
| `make oracle-classify` | [docs/oracle-classify.md](docs/oracle-classify.md) |
| `make oracle-engine [DB=…] [NS=…] [TRANSPORT=local\|tcp\|procs]` | [docs/oracle.md](docs/oracle.md) ("Engine mode") |
| `make bracken-check` | [docs/bracken-check.md](docs/bracken-check.md) |
| `make oracle-cohort [DB=…]` | [docs/oracle.md](docs/oracle.md) ("Cohort mode") |
| `make stage-cohort [PART=record\|stage]` (and `runs/stage-cohort.json`) | [docs/cohort.md](docs/cohort.md) |
| `make tag-objects [PREFIX=…]` | [docs/tag-objects.md](docs/tag-objects.md) |
| `make sortfuzz [SORTFUZZ=quick\|full]` | [docs/sortfuzz.md](docs/sortfuzz.md) |
| `make hitorderfuzz [HITORDERFUZZ=quick\|full]` / `make hitorder-golden` | [docs/hitorderfuzz.md](docs/hitorderfuzz.md), [docs/hitorder.md](docs/hitorder.md) |
| `make g3-spec` / `make g3-tables` / `make g3-frontier` / `make g3-fit` | [docs/cohort.md](docs/cohort.md) |
| `make bash-jobs-test` | [docs/cohort.md](docs/cohort.md) |
| G3 probes (staging, contention, decompression, hitbench, host tunes) / `make hosttune-test` | [docs/probes.md](docs/probes.md) |
| `make lever-test` (the ladder lever library, `scripts/g3/lever.sh`) | [docs/ladder.md](docs/ladder.md) |
| `make loadbench [DB=…] [THREADS=…]` | [docs/loadbench.md](docs/loadbench.md) |
| `make g2 [PART=…]` (and `runs/g2-*.json`) | [docs/g2.md](docs/g2.md) |
| `make ami` | [docs/ami.md](docs/ami.md) |
| `make rehearse SPEC=…` (local rehearsal of a spec under the nodes' environment; runs `make util-stream-test` first) | [docs/cohort.md](docs/cohort.md) |
| `make util-stream-test [N=…]` / `make util DIR=…` / `make util-backfill` / `make instance-types` | [docs/util.md](docs/util.md), [docs/run.md](docs/run.md) ("Utilisation") |
| `make run GATE=… SPEC=… [NODES=n]` | [docs/run.md](docs/run.md) ("Multi-node runs"), [docs/engine.md](docs/engine.md) |
| `make orphans` | [docs/orphans.md](docs/orphans.md) |
| `make report GATE=… RUN=…` | [docs/report.md](docs/report.md) |
| spore.host usage notes | [docs/spore-host.md](docs/spore-host.md) |

Every run writes `results/<gate>/<run-id>/` with `manifest.json` (commit SHA, upstream pin, AMI
ID, instance type and count, truffle price at launch, region and AZ, dataset ETag and version,
sample accessions, start/stop times), raw logs, per-phase timings, request counts and derived
tables. **Reports cite only these files; a number not traceable to a manifest is a defect.**

## Code layout

| path | what |
|---|---|
| `cmd/aws-kraken2` | the classifier CLI (flags mirror upstream's `kraken2` wrapper) |
| `cmd/k2probe` | G0 probes: `header`, `opts`, `equiv-hash`, `equiv-scan` |
| `internal/kdb` | `opts.k2d`, `hash.k2d` header, cell-width detection |
| `internal/chash` | fmix64, compact hash cell decode, linear/double probe (counts probes), RAM and mmap loads |
| `internal/mmscan` | minimizer scanner (`mmdump`: the harness stream format) |
| `internal/taxo` | `taxo.k2d` taxonomy |
| `internal/classify` | per-read classification, ResolveTree, hit-list formatting |
| `internal/seqio` | FASTA/FASTQ reader, paired input, gzip (klauspost/compress), `-Q` masking |
| `internal/seqout` | `--classified-out` / `--unclassified-out` formatting |
| `internal/report` | kraken-style and mpa-style `--report` |
| `internal/engine` | sharded resident table: slot-range shards with overlap tails, router, TCP transport, S3 rendezvous, emitter protocol |
| `internal/objstore` | S3 multipart writer (lazy create, parts in read order) and its local emulation |
| `internal/oracletest` | locates the shared oracle artifacts for tests (same rule as `scripts/paths.sh`) |
| `upstream/` | oracle harnesses (C++ linked against upstream at the pin; not in the core path) |
| `scripts/` | everything a make target runs |
| `.github/workflows/` | CI: build, test, lint, `make oracle DB=viral` on Linux aarch64 |

## Ported-file header

```go
// Ported from DerrickWood/kraken2 src/<file> at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.
```

## Working method

- Independent work runs in parallel subagents, each in its own git worktree and branch, scoped
  to one issue, with its own oracle or acceptance test. They report to the coordinator.
- Subagents do not push to main, close milestones or issues, or report outcomes to Scott.
- Before any merge, a separate reviewer checks the diff against the six laws: oracle coverage,
  baseline fairness, hygiene steps, per-lever attribution.

## Hard-won process notes (from the motivating page)

- `spawn launch --command` runs under `bash -e` (`$-` = `ehB`); `set -uo pipefail` does not
  clear it. Always `set +e` and check statuses by hand (spawn#707).
- Cross-region placement is silent. `InvalidInstanceID.NotFound` usually means wrong region.
- A probe must stream its result; report-at-the-end loses everything to a TTL kill.
- Containers run as the image's user: output dirs need `chmod 1777`; never `rm` a staged input.
- A heredoc binds to the last command in a pipeline.
- No `drop_caches` between rungs = every rung after the first is warm.
- A null result from a probe that can't resolve the effect is not evidence: compute the
  resolution (e.g. mean spacing) first.
