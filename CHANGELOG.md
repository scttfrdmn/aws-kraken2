# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- `internal/classify`: per-read classification (ClassifySequence's minimizer loop, ResolveTree,
  `--quick`, `--confidence`, `--minimum-hit-groups`, `-F`) and the `--output` line (#13, #14), with
  the `upstream/classify_trace.cc` oracle harness, `make harness` and `make oracle-classify`.
