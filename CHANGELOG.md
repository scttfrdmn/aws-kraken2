# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- `internal/chash`: port of upstream's compact hash lookup path (fmix64, 32- and 40-bit cells, linear and double probing, RAM and mmap loaders, `CellSource` probe over `io.ReaderAt`); `upstream/chash_dump.cc` and `upstream/chash_keys.cc` oracle harnesses; `k2probe equiv-hash`; `make harness` and `make g0b` (#4).
