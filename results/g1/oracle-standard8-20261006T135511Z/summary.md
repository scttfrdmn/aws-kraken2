# make oracle: standard8, 20261006T135511Z

Upstream `kraken2` at `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) vs `bin/aws-kraken2` at `a4862ab8c7deeda17632b5473470acd954f12a73` (dirty: false), on Darwin arm64.
NOT the canonical platform (Linux aarch64): development evidence only.

| | count |
|---|---|
| comparison cases | 59 |
| output files compared (both sides) | 260 |
| cases identical (all files, stdout and exit status) | 59 |
| cases differing | 0 |
| upstream exit other than expected | 0 |
| requested output missing, or expected-absent output present | 0 |
| cases with unexpected files | 0 |
| stderr differs after removing timings (informational, not under Law 1) | 0 |
| control cases (one option changed on our side only) | 2 |
| control cases flagged (same exit, at least one output file differs) | 2 |

Timings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream 29.1s, ours 24.0s. Sum of the classification phase as each reports it on stderr ("processed in"): upstream 14.28s, ours 10.61s.

## Coverage checks (Law 4: could the matrix have seen the effect?)

| check | value | want | ok |
|---|---|---|---|
| se-short: single-end reads with an empty hit list (0:0) | 52308 | gt 0 | yes |
| pe-short: pairs whose hit list ends at the mate border (|:|) | 76922 | gt 0 | yes |
| pe-short: pairs with no minimizers at all (hit list |:|) | 27692 | gt 0 | yes |
| pe-slash: --output IDs still ending in /1 or /2 (trimmed in paired mode) | 0 | eq 0 | yes |
| pe-slash: sequence-output IDs ending in /1 (kept as read) | 200000 | gt 0 | yes |
| se-slash: --output IDs ending in /1 (not trimmed single-end) | 200000 | gt 0 | yes |
| se-q20: bases masked to x in the sequence outputs | 1178230 | gt 0 | yes |
| se-q20 vs se-default (S1): -Q 20 changes --output | f4d0508ed2de85b6701fdf6f16db438c2bd087e0cdbd4fdb14ca115775f8240d | ne 3a8c83c07902033a7c4edd6a0feee535a57b123347df9174664b432d2e2ce28b | yes |
| pe-t1 (1 thread, plain) vs pe-default-gz (8 threads, gzip), S1: same --output | 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | eq 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| pe-mmap vs pe-default-gz, S1: same --output | 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | eq 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| pe-quick vs pe-default-gz, S1: --quick changes --output | 2d1fca6385133c7db859cef9b6e7bb921d33afc8751f1edf3ebed7e11b8201ed | ne 527068d2bc8e30eeb7f0cee9152649dc7cb370fbb65d538a322491ff6b6eb074 | yes |
| minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs) | 17113767929583441920 | info | - |

Per-case arguments, exit statuses, timings and sha256 of every output on both sides:
`cases.tsv`. Run metadata: `manifest.json`. Log with first differing lines: `run.log`.
Case design: docs/oracle.md.
