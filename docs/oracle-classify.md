# make oracle-classify / make harness

**What:** checks that `internal/classify` (per-read classification and the `--output` line)
is byte-identical to upstream at the pin. `scripts/classify-oracle.sh` builds the
`upstream/classify_trace.cc` harness (via `scripts/harness-build.sh`). The harness runs
upstream's own FastReader, MinimizerScanner, CompactHashTable and Taxonomy over real reads. It
writes each read's event stream: per mate, every (minimizer, ambiguous, looked-up value), in
scanner order. It also writes a taxonomy dump (internal ID, parent, external ID, name). Then the
script runs upstream `kraken2 --output` over the option matrix, plus `classify -F` and a
`--report`. The Go test `TestEquivUpstream*` replays the traces through `internal/classify`
and byte-compares its output.

`make harness NAME=<name>` builds any `upstream/<name>.cc` against the pinned sources with
src/Makefile's flags (`-fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING`).

**Inputs:** `make oracle` (upstream built at the pin in `.oracle/`), the Viral DB and the reads
under the main checkout's `.cache/`. Override them with `DB=`, `READS=` (path prefix before
`_1.fq`/`_2.fq`), and `CLASSIFY_ORACLE=` (the output directory, default `.cache/classify`).

**Outputs:** `$(CLASSIFY_ORACLE)/{se,pe}.trace`, `taxo.tsv`, `{se,pe}/<config>.out`, `.log`,
`default.report`, `MANIFEST` (pin, build, DB, reads, configs), and `equiv.log` (the test output).

**Failure looks like:** a `--- FAIL` line naming the mode and config, with the count of differing
lines and the first one (got vs want). Any difference is a defect (Law 1). Without the oracle
directory, the test skips.
