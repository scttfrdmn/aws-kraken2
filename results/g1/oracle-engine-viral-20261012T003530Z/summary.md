# make oracle-engine: viral, 20261012T003530Z (shard counts 1 2 3 4 8, transport local, tail 302 default)

Upstream `kraken2` at `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) vs `bin/aws-kraken2` at `9126a6f49bc485eca54b75619b60564058ff1d86` (dirty: false), on Darwin arm64.
NOT the canonical platform (Linux aarch64): development evidence only.
Decompression: ours in process (AK2_DECOMPRESS=''); gzip on PATH: gzip 1.12 (/tmp/gnugzip/inst/bin/gzip).

| | count |
|---|---|
| comparison cases | 330 |
| output files compared (both sides) | 1495 |
| cases identical (all files, stdout and exit status) | 330 |
| cases differing | 0 |
| upstream exit other than expected | 0 |
| requested output missing, or expected-absent output present | 0 |
| cases with unexpected files | 0 |
| stderr differs after removing timings (informational, not under Law 1) | 35 |
| control cases (one option changed on our side only) | 10 |
| control cases flagged (same exit, at least one output file differs) | 10 |

stderr differs (informational): se-trunc-gz-trunc@n1 se-trunc-gz-trunc@n2 se-trunc-gz-trunc@n3 se-trunc-gz-trunc@n4 se-trunc-gz-trunc@n8 pe-trunc-garbage-gz-trunc@n1 pe-trunc-garbage-gz-trunc@n2 pe-trunc-garbage-gz-trunc@n3 pe-trunc-garbage-gz-trunc@n4 pe-trunc-garbage-gz-trunc@n8 se-garbage-gz-garbage@n1 se-garbage-gz-garbage@n2 se-garbage-gz-garbage@n3 se-garbage-gz-garbage@n4 se-garbage-gz-garbage@n8 se-zeropad-gz-zeropad@n1 se-zeropad-gz-zeropad@n2 se-zeropad-gz-zeropad@n3 se-zeropad-gz-zeropad@n4 se-zeropad-gz-zeropad@n8 pe-gz-then-plain-mixgz@n1 pe-gz-then-plain-mixgz@n2 pe-gz-then-plain-mixgz@n3 pe-gz-then-plain-mixgz@n4 pe-gz-then-plain-mixgz@n8 se-gzflag-missing-missing@n1 se-gzflag-missing-missing@n2 se-gzflag-missing-missing@n3 se-gzflag-missing-missing@n4 se-gzflag-missing-missing@n8 se-gzflag-plain-S1@n1 se-gzflag-plain-S1@n2 se-gzflag-plain-S1@n3 se-gzflag-plain-S1@n4 se-gzflag-plain-S1@n8

Timings (informational, not a benchmark: one run each, warm page cache, development host unless the manifest says otherwise). Wall-clock sum over the comparison cases, whole process including DB load: upstream 126.7s, ours 85.5s. Sum of the classification phase as each reports it on stderr ("processed in"): upstream 105.68s, ours 67.93s.

## Coverage checks (Law 4: could the matrix have seen the effect?)

| check | value | want | ok |
|---|---|---|---|
| se-short: single-end reads with an empty hit list (0:0) | 52308 | gt 0 | yes |
| pe-short: pairs whose hit list ends at the mate border (|:|) | 76922 | gt 0 | yes |
| pe-short: pairs with no minimizers at all (hit list |:|) | 27692 | gt 0 | yes |
| pe-slash: --output IDs still ending in /1 or /2 (trimmed in paired mode) | 0 | eq 0 | yes |
| pe-slash: sequence-output IDs ending in /1 (kept as read) | 200000 | gt 0 | yes |
| se-slash: --output IDs ending in /1 (not trimmed single-end) | 200000 | gt 0 | yes |
| se-trunc-gz: --output records from the half-length .gz (some reached classify) | 98762 | gt 0 | yes |
| se-trunc-gz: --output records from the half-length .gz (fewer than the 200000 reads) | 98762 | lt 200000 | yes |
| se-trunc-gz: lines the decompressor wrote to upstream's stderr (so the next check can resolve) | 5 | gt 0 | yes |
| se-zeropad-gz: --output records before the zero padding (some reached classify) | 200000 | gt 0 | yes |
| se-trunc-gz: runs of ours that logged in-process decompression (default: every run) | 5 | eq 5 | yes |
| se-trunc-gz: upstream's decompressor lines missing from ours' stderr (default: some, ours did not run the tool) | 5 | gt 0 | yes |
| se-garbage-gz: --output records before the garbage tail (some reached classify) | 200000 | gt 0 | yes |
| se-q20: bases masked to x in the sequence outputs | 1178230 | gt 0 | yes |
| se-q20 vs se-default (S1): -Q 20 changes --output | 9cedeb5c56b1fa9e686737b8d599bce15b07faac4d9b4e123c9255ab5dd151ed | ne 546f76b00aa4dd848e4c55c4ff89001d77b3ac88bc618080c63743712a753531 | yes |
| pe-t1 (1 thread, plain) vs pe-default-gz (8 threads, gzip), S1: same --output | bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | eq bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| pe-mmap vs pe-default-gz, S1: same --output | bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | eq bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| pe-quick vs pe-default-gz, S1: --quick changes --output | 187aae78b2bbc90851eaf1e3c6b453cae4ffbbc5c0c0db05d2fe59f3c56abbe3 | ne bebbf3380833d5da28c6a6dce448303048d70fb295acc72b85b7dcb11e2c5c0f | yes |
| engine N=2: lookups whose probe ended in a shard's overlap tail, summed over cases (real-data reach of the tail path; synthetic coverage: internal/engine tests) | 0 | info | - |
| engine N=2: of those, ended past slot C-1 in the last shard's wrapped tail | 0 | info | - |
| engine N=3: lookups whose probe ended in a shard's overlap tail, summed over cases (real-data reach of the tail path; synthetic coverage: internal/engine tests) | 18 | info | - |
| engine N=3: of those, ended past slot C-1 in the last shard's wrapped tail | 0 | info | - |
| engine N=4: lookups whose probe ended in a shard's overlap tail, summed over cases (real-data reach of the tail path; synthetic coverage: internal/engine tests) | 15 | info | - |
| engine N=4: of those, ended past slot C-1 in the last shard's wrapped tail | 0 | info | - |
| engine N=8: lookups whose probe ended in a shard's overlap tail, summed over cases (real-data reach of the tail path; synthetic coverage: internal/engine tests) | 15 | info | - |
| engine N=8: of those, ended past slot C-1 in the last shard's wrapped tail | 0 | info | - |
| engine resolution: real lookups reached a tail at N = 3 4 8 (48 in all) but at N = 2 none did; the read-level matrix exercises the tail path only that often, so the main evidence for it is TestRealDBBoundaries (real tables, every boundary run) and the synthetic tests in internal/engine | 48 | info | - |
| minimum_acceptable_hash_value (nonzero: the subthreshold skip path runs) | 0 | info | - |

Per-case arguments, exit statuses, timings and sha256 of every output on both sides:
`cases.tsv`. Run metadata: `manifest.json`. Log with first differing lines: `run.log`.
Case design: docs/oracle.md.
