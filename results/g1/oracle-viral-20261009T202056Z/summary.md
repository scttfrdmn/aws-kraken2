# make oracle: viral, 20261009T202056Z

Upstream `kraken2` at `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) vs `bin/aws-kraken2` at `7bb930d4fcc77a4355aab8303fd31ea2e1527c68` (dirty: false), on Darwin arm64.
NOT the canonical platform (Linux aarch64): development evidence only.
Decompression: ours gzip -dc / bzip2 -dc from PATH (as the wrapper) (AK2_DECOMPRESS='pipe'); gzip on PATH: shim gzip -dc: rapidgzip version 0.14.5; otherwise: gzip 1.12 (/tmp/ak2-48-tools/shim-rapidgzip/gzip).

| | count |
|---|---|
| comparison cases | 65 |
| output files compared (both sides) | 294 |
| cases identical (all files, stdout and exit status) | 65 |
| cases differing | 0 |
| upstream exit other than expected | 0 |
| requested output missing, or expected-absent output present | 0 |
| cases with unexpected files | 0 |
| stderr differs after removing timings (informational, not under Law 1) | 0 |
| control cases (one option changed on our side only) | 2 |
| control cases flagged (same exit, at least one output file differs) | 2 |

Timings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream 22.1s, ours 13.9s. Sum of the classification phase as each reports it on stderr ("processed in"): upstream 17.89s, ours 11.24s.

## Coverage checks (Law 4: could the matrix have seen the effect?)

| check | value | want | ok |
|---|---|---|---|
| se-short: single-end reads with an empty hit list (0:0) | 52308 | gt 0 | yes |
| pe-short: pairs whose hit list ends at the mate border (|:|) | 76922 | gt 0 | yes |
| pe-short: pairs with no minimizers at all (hit list |:|) | 27692 | gt 0 | yes |
| pe-slash: --output IDs still ending in /1 or /2 (trimmed in paired mode) | 0 | eq 0 | yes |
| pe-slash: sequence-output IDs ending in /1 (kept as read) | 200000 | gt 0 | yes |
| se-slash: --output IDs ending in /1 (not trimmed single-end) | 200000 | gt 0 | yes |
| se-trunc-gz: --output records from the half-length .gz (some reached classify) | 97399 | gt 0 | yes |
| se-trunc-gz: --output records from the half-length .gz (fewer than the 200000 reads) | 97399 | lt 200000 | yes |
| se-trunc-gz: runs of ours that logged in-process decompression (AK2_DECOMPRESS=pipe: none) | 0 | eq 0 | yes |
| se-garbage-gz: --output records before the garbage tail (some reached classify) | 196638 | gt 0 | yes |
| se-q20: bases masked to x in the sequence outputs | 1178230 | gt 0 | yes |
| se-q20 vs se-default (S1): -Q 20 changes --output | 9cedeb5c56b1fa9e686737b8d599bce15b07faac4d9b4e123c9255ab5dd151ed | ne 546f76b00aa4dd848e4c55c4ff89001d77b3ac88bc618080c63743712a753531 | yes |
| pe-t1 (1 thread, plain) vs pe-default-gz (8 threads, gzip), S1: same --output | bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | eq bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| pe-mmap vs pe-default-gz, S1: same --output | bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | eq bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| pe-quick vs pe-default-gz, S1: --quick changes --output | 187aae78b2bbc90851eaf1e3c6b453cae4ffbbc5c0c0db05d2fe59f3c56abbe3 | ne bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs) | 0 | info | - |

Per-case arguments, exit statuses, timings and sha256 of every output on both sides:
`cases.tsv`. Run metadata: `manifest.json`. Log with first differing lines: `run.log`.
Case design: docs/oracle.md.
