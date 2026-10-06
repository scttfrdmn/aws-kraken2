# make equiv-seqout

**What:** checks `internal/seqio` (FASTA/FASTQ reading, paired input, gzip) and
`internal/seqout` (`--classified-out` / `--unclassified-out`) against upstream kraken2 at the pin,
without the classifier port. Upstream runs on real reads against the Viral DB with `--output`,
`--classified-out` and `--unclassified-out`. The Go test `TestOracleSeqout` then reads the same
input with seqio, takes each read's class and taxid from upstream's `--output` (columns 1 and 3),
writes the outputs with seqout and byte-compares them with upstream's. It also checks each
record's ID against column 2 and its length against column 4.

Cases: FASTQ single-end and paired, plain, gzip (auto-detected and `--gzip-compressed`),
`--minimum-base-quality 20`, FASTA (single-line, wrapped at 60 columns, gzip), CRLF line ends, and
mate suffixes in the identifier with a tab before the comment. The FASTA, CRLF and suffix inputs
are the same real reads reformatted with awk. Extra samples get the four plain/gzip FASTQ cases.

**Inputs:** the oracle install `.oracle/<pin>/kraken2`, the Viral DB
`.cache/db/k2_viral_20260626` (`scripts/fetch-db.sh`), and reads `.cache/reads/<run>_<N>_{1,2}.fq{,.gz}`
(`scripts/fetch-reads.sh`). These paths are taken from the main checkout, so the target also works
in a worktree. Usage: `scripts/equiv-seqout.sh [stem [extra-stem…]]`. The default stem is
`SRR062634_200000`; `ERR478965_200000` is added as an extra stem when it has been fetched.

**Outputs:** upstream outputs under `.cache/equiv-seqout/<date>/` (large, not checked in), and
`results/g1/seqio-seqout-<date>/` with `commands.txt` (exact upstream commands), `run.log`,
`summary.tsv` (per output file: records, classified, ID/length mismatches, bytes, both SHA-256
values, identical) and `manifest.json` (commit, pin, host, DB and reads SOURCE).

**Failure looks like:** a non-zero exit, `--- FAIL` in `run.log`, or a `false` in the
`identical` column of `summary.tsv`. Any difference is a defect (Law 1).
