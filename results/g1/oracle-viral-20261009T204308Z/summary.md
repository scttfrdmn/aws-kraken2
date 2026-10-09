# make oracle: viral, 20261009T204308Z

Upstream `kraken2` at `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) vs `bin/aws-kraken2` at `7bb930d4fcc77a4355aab8303fd31ea2e1527c68` (dirty: false), on Darwin arm64.
NOT the canonical platform (Linux aarch64): development evidence only.
Decompression: ours in process (AK2_DECOMPRESS=''); gzip on PATH: shim gzip -dc: pigz 2.8; otherwise: gzip 1.12 (/tmp/ak2-48-tools/shim-pigz/gzip).

**Filtered run (ORACLE_CASES='trunc|garbage'): not the full matrix.**

| | count |
|---|---|
| comparison cases | 3 |
| output files compared (both sides) | 17 |
| cases identical (all files, stdout and exit status) | 1 |
| cases differing | 2 |
| upstream exit other than expected | 0 |
| requested output missing, or expected-absent output present | 0 |
| cases with unexpected files | 0 |
| stderr differs after removing timings (informational, not under Law 1) | 3 |
| control cases (one option changed on our side only) | 0 |
| control cases flagged (same exit, at least one output file differs) | 0 |

Differing cases:
- se-trunc-gz-trunc
- pe-trunc-garbage-gz-trunc

stderr differs (informational): se-trunc-gz-trunc pe-trunc-garbage-gz-trunc se-garbage-gz-garbage

Timings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream 0.8s, ours 0.7s. Sum of the classification phase as each reports it on stderr ("processed in"): upstream 0.32s, ours 0.28s.

## Coverage checks (Law 4: could the matrix have seen the effect?)

| check | value | want | ok |
|---|---|---|---|
| se-short: single-end reads with an empty hit list (0:0) | n/a | gt 0 | no |
| pe-short: pairs whose hit list ends at the mate border (|:|) | n/a | gt 0 | no |
| pe-short: pairs with no minimizers at all (hit list |:|) | n/a | gt 0 | no |
| pe-slash: --output IDs still ending in /1 or /2 (trimmed in paired mode) | n/a | eq 0 | no |
| pe-slash: sequence-output IDs ending in /1 (kept as read) | n/a | gt 0 | no |
| se-slash: --output IDs ending in /1 (not trimmed single-end) | n/a | gt 0 | no |
| se-trunc-gz: --output records from the half-length .gz (some reached classify) | 98645 | gt 0 | yes |
| se-trunc-gz: --output records from the half-length .gz (fewer than the 200000 reads) | 98645 | lt 200000 | yes |
| se-trunc-gz: runs of ours that logged in-process decompression (default: every run) | 1 | eq 1 | yes |
| se-garbage-gz: --output records before the garbage tail (some reached classify) | 200000 | gt 0 | yes |
| se-q20: bases masked to x in the sequence outputs | n/a | gt 0 | no |
| se-q20 vs se-default (S1): -Q 20 changes --output | n/a | ne x | no |
| pe-t1 (1 thread, plain) vs pe-default-gz (8 threads, gzip), S1: same --output | a | eq b | no |
| pe-mmap vs pe-default-gz, S1: same --output | a | eq b | no |
| pe-quick vs pe-default-gz, S1: --quick changes --output | n/a | ne x | no |
| minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs) | 0 | info | - |

Per-case arguments, exit statuses, timings and sha256 of every output on both sides:
`cases.tsv`. Run metadata: `manifest.json`. Log with first differing lines: `run.log`.
Case design: docs/oracle.md.
