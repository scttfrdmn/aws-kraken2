# make oracle-cohort: standard8, 20261009T202937Z

Upstream at `2731b35f7abb26ec926517274f3d87e78d42fd76` per sample vs the engine's cohort mode at `7bb930d4fcc77a4355aab8303fd31ea2e1527c68` (dirty: false), on Darwin arm64.
Decompression: ours gzip -dc / bzip2 -dc from PATH (as the wrapper) (AK2_DECOMPRESS='pipe'); gzip on PATH: shim gzip -dc: gzip 1.12; otherwise: gzip 1.12 (/tmp/ak2-48-tools/shim-gnu/gzip).

| mode | samples | passed | control flagged |
|---|---|---|---|
| n1 | 10 | 10 | yes |
| n3 | 10 | 10 | yes |
| n3-lpt | 10 | 10 | yes |
| n3-sdk | 10 | 10 | yes |
| n3-striped | 10 | 10 | yes |

Per sample: `samples.tsv` (exit statuses, file counts, identical files, file sets). Log: `run.log`.
