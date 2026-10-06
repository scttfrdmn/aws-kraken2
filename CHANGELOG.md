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
- G0a spec `runs/g0a.json`, post-processing `scripts/post/g0a.sh`, and its first run under
  `results/g0a/` (#3).
- `internal/chash`: port of upstream's compact hash lookup path (fmix64, 32- and 40-bit cells, linear and double probing, RAM and mmap loaders, `CellSource` probe over `io.ReaderAt`); `upstream/chash_dump.cc` and `upstream/chash_keys.cc` oracle harnesses; `k2probe equiv-hash`; `make harness` and `make g0b` (#4).
- `internal/mmscan`: port of upstream's `MinimizerScanner` (DNA and protein, both revcom versions,
  `LoadSequence` intervals, zero allocations per minimizer). It is checked against upstream by
  `upstream/mm_dump.cc`, `k2probe equiv-scan` and `make g0b PART=scan`. `scripts/harness-build.sh`
  builds the oracle harnesses (#5).
