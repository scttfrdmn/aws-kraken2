# make oracle: standard8, 20261009T202056Z

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
| stderr differs after removing timings (informational, not under Law 1) | 3 |
| control cases (one option changed on our side only) | 2 |
| control cases flagged (same exit, at least one output file differs) | 2 |

stderr differs (informational): pe-gz-then-plain-mixgz se-gzflag-missing-missing se-gzflag-plain-S1

Timings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream 31.6s, ours 30.2s. Sum of the classification phase as each reports it on stderr ("processed in"): upstream 11.79s, ours 12.07s.

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
| se-q20 vs se-default (S1): -Q 20 changes --output | f4d0508ed2de85b6701fdf6f16db438c2bd087e0cdbd4fdb14ca115775f8240d | ne 3a8c83c07902033a7c4edd6a0feee535a57b123347df9174664b432d2e2ce28b | yes |
| pe-t1 (1 thread, plain) vs pe-default-gz (8 threads, gzip), S1: same --output | 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | eq 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| pe-mmap vs pe-default-gz, S1: same --output | 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | eq 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| pe-quick vs pe-default-gz, S1: --quick changes --output | 2d1fca6385133c7db859cef9b6e7bb921d33afc8751f1edf3ebed7e11b8201ed | ne 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs) | 17113767929583441920 | info | - |

Per-case arguments, exit statuses, timings and sha256 of every output on both sides:
`cases.tsv`. Run metadata: `manifest.json`. Log with first differing lines: `run.log`.
Case design: docs/oracle.md.
