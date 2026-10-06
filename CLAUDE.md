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
  (2026-10-01; `git describe` = `2.17.2-20-g2731b35`). Oracle *and* baseline. Defined once in
  `scripts/pin.env`.
- All AWS runs go through spore.host (`spawn`, `truffle`, `lagotto`, `spored`, `cohort`), via
  `make run`. Every run has a TTL and a `cost_limit`, and `make orphans` afterwards (nf-spawn#96).
- Containers come from aarch.bio, pinned by digest, with a flat `/tmp` layout (spawn#555).
- AWS account: `AWS_PROFILE=aws`.

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
| `make oracle [DB=viral\|standard8\|all]` / `make stage-db DB=…` | [docs/oracle.md](docs/oracle.md) |
| `make harness [NAME=…] [VARIANTS=…]` | [docs/harness.md](docs/harness.md) |
| `make g0b [G0B=hash\|scan\|all]` | [docs/g0b.md](docs/g0b.md) |
| `make equiv-seqout` | [docs/equiv-seqout.md](docs/equiv-seqout.md) |
| `make oracle-classify` | [docs/oracle-classify.md](docs/oracle-classify.md) |
| `make ami` | [docs/ami.md](docs/ami.md) |
| `make run GATE=… SPEC=…` | [docs/run.md](docs/run.md) |
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
