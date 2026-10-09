# make equiv-seqout

**What:** checks `internal/seqio` (FASTA/FASTQ reading, paired input, gzip/bzip2) and
`internal/seqout` (`--classified-out` / `--unclassified-out`) against upstream kraken2 at the pin,
without the classifier port. Upstream runs on real reads against the Viral DB with `--output`,
`--classified-out` and `--unclassified-out`. The Go test `TestOracleSeqout` then reads the same
input through seqio's production path (`LoadBlock`/`LoadBlocks` at `DefaultBlockBytes`, then
`Parse`/`PairBlocks`). It takes each read's class and taxid from upstream's `--output`
(columns 1 and 3), writes the outputs with seqout and byte-compares them with upstream's. It also
checks each record's ID against column 2 and its length against column 4, and that the run ends
the way upstream's does: exit 0, or exit 65 with upstream's malformed-record or mate-count
message. For an empty first input, it checks that no output file is created. `TestOracleDecompress`
compares the bytes seqio decompresses with what `gzip -dc` / `bzip2 -dc` output, since that is
what the wrapper hands to classify.

Cases (30 on the main stem):
- FASTQ single-end and paired, plain, gzip (auto-detected and `--gzip-compressed`), and
  `--minimum-base-quality 20`.
- FASTA: single-line, wrapped at 60 columns, and gzip.
- CRLF line ends, and mate suffixes in the identifier with a tab before the comment.
- gzip: multi-member, trailing zero padding, trailing garbage, truncated at half, and
  `--gzip-compressed` on a plain file (upstream sees an empty stream).
- bzip2: auto-detected, flagged, paired, and with trailing garbage.
- Malformed qualities (exit 65), each mate file 10 records short (exit 65), empty input, and no
  final newline (FASTQ and FASTA).

All inputs are the real reads, reformatted or damaged with awk, head, perl, gzip and bzip2. Each
extra stem gets the four plain/gzip FASTQ cases. The script fails if any upstream run's exit
status differs from the one its case expects, or if fewer cases ran than expected.

**Inputs:** the oracle install `.oracle/<pin>/kraken2`, the Viral DB
`.cache/db/k2_viral_20260626` (`scripts/fetch-db.sh`), and reads `.cache/reads/<run>_<N>_{1,2}.fq{,.gz}`
(`scripts/fetch-reads.sh`). These paths are taken from the main checkout, so the target also works
in a worktree. Usage: `scripts/equiv-seqout.sh [stem [extra-stem…]]`. The default stem is
`SRR062634_200000`; `ERR478965_200000` is added as an extra stem when it has been fetched.

**Decompressors:** the canonical oracle platform is Linux aarch64, with GNU gzip and bzip2 1.0.x.
macOS's `/usr/bin/gzip` is Apple's. On a truncated stream it drops its last partial 64 KiB of
output, so `se_fq_gz_truncated` fails against it. On macOS, set `DECOMP_BIN` to a directory holding
GNU gzip, for example one built from `gzip-1.12.tar.gz` with `./configure --prefix=…; make install`:
`DECOMP_BIN=/path/to/bin make equiv-seqout`. Without `DECOMP_BIN`, a build at `/tmp/gnugzip/inst/bin` is used if present (as `make oracle` does). The script uses that directory both for its own
reference outputs and for upstream's wrapper, which finds gzip on `PATH`. The manifest records the
gzip and bzip2 versions used.

**Pipe mode (#48):** with `AK2_DECOMPRESS=pipe`, both Go tests read compressed inputs through
`seqio.OpenPipe`, which runs the `gzip -dc` / `bzip2 -dc` on `PATH` as the wrapper does, in place
of the in-process path. The manifest records `ak2_decompress` and the gzip path. With a shim from
`scripts/decomp-shim.sh` in `DECOMP_BIN` (see [oracle.md](oracle.md), "Decompressor shims"),
upstream's exit on a damaged input can change. GNU gzip and pigz ignore zero padding and trailing
garbage after the member. rapidgzip 0.14.5 drops the end of the member's output before them, so
the last record is cut and upstream exits 65. `se_fq_gz_zeropad` and `se_fq_gz_garbage` therefore
accept `0,65`, and ours must exit as upstream did.

How much rapidgzip drops depends on `-P`. The figures are from a 16-core macOS host
(`results/g1/rapidgzip-tail-loss-20261009T210618Z/`), each repeated twice with identical output:

| input | default `-P` (= 16 here), and 2-16 | `-P 1` |
|---|---|---|
| SRR062634 mate 1 + 4096 zero bytes, or + a garbage line | 703,060 of 51,895,574 bytes | 10,987,518 |

For ERR478965 mate 1 + a garbage line (47,238,491 bytes), it drops 793,682 at the default and at
8 or 16, 2,493,064 at 2, and 4,302,739 at 1 and 4.

So the size of the loss, and which records survive, depend on the thread count and on the
host's core count. The shim uses rapidgzip's default `-P`. `TestOracleDecompress` passes under
pipe mode, because OpenPipe hands on rapidgzip's own bytes.

**Outputs:** upstream outputs under `.cache/equiv-seqout/<UTC timestamp>/` (large, not checked
in). The work directory records `decompressor` (`AK2_DECOMPRESS`, `DECOMP_BIN`, the gzip path and
version, and whether those are the defaults) and `result` (PASS or FAIL). The symlink
`.cache/equiv-seqout/latest` is what `go test` uses when `K2_SEQOUT_ORACLE` / `K2_DECOMP_ORACLE`
are unset, so `make test` and CI run both oracle tests. It is shared by every worktree, so it
moves only for a PASS with the defaults (`AK2_DECOMPRESS` unset, no `DECOMP_BIN`). The tests fail
loudly on a `latest` that is not such a run ([build.md](build.md)). Absent data is a skip, or a
failure with `AWS_KRAKEN2_REQUIRE_ORACLE=1`. The run also writes
`results/g1/seqio-seqout-<UTC timestamp>/` with these files:
- `commands.txt`: the exact upstream commands.
- `run.log`.
- `summary.tsv`: per output file, the records, classified count, ID/length mismatches, both exit
  statuses, bytes, both SHA-256 values and whether they are identical.
- `decompress.tsv`.
- `manifest.json`: result, commit, pin, sha256 of `classify`, Go, gzip and bzip2 versions, host,
  and the DB and reads SOURCE.

**Failure looks like:** a non-zero exit, `FAIL` in `run.log`, `"result": "FAIL"` in the manifest,
or a `false` in an `identical` column. Any difference is a defect (Law 1).
