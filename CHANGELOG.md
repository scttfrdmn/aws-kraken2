# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- `internal/taxo`: `taxo.k2d` reader ported from upstream `taxonomy.{h,cc}` (node fields, names,
  ranks, external-ID map, `IsAAncestorOfB`, `LowestCommonAncestor`, the `taxo.Tree` interface),
  checked against upstream's own `Taxonomy` class via `upstream/taxo_dump.cc` (#11).
- `internal/report`: kraken-style `--report` and `--use-mpa-style` ported from upstream
  `reports.{h,cc}`, including `--report-zero-counts` and libstdc++'s `std::sort` tie order for
  siblings; byte-identical to upstream's reports on real reads (#15).
- `scripts/harness-build.sh`: builds `upstream/<name>.cc` oracle harnesses against the pinned
  sources with upstream's compiler flags.
