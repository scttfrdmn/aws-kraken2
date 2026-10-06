# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- `internal/seqio` (FASTA/FASTQ reader ported from upstream `fast_reader`, two-file and interleaved
  pairs, gzip/bzip2 input with the wrapper's detection and `gzip -dc`'s behaviour on damaged
  streams, quality masking with Linux aarch64 unsigned-char semantics) and `internal/seqout`
  (`--classified-out`/`--unclassified-out` writers, ordered batch output). `make equiv-seqout`
  checks both byte-for-byte against upstream on Viral (#12, #16).
