# make g0b (scripts/g0b.sh)

**What:** G0b equivalence probes. Each part compares a Go port with upstream's own code at the pin
over real reads and stops at the first difference.

- `scan` (issue #5): `internal/mmscan` against upstream's `MinimizerScanner`.
- `all`: every part.

`make g0b PART=scan` runs `scripts/g0b.sh scan`.

## scan

1. `scripts/harness-build.sh mm_dump` builds `upstream/mm_dump.cc` against the pinned sources.
   It uses the `CXXFLAGS` that `src/Makefile` computes (`-fopenmp ... -O3 ... -DLINEAR_PROBING`) and
   Homebrew `g++-N` on macOS. The output goes to `.oracle/harness/mm_dump`, with a `.BUILD` file
   recording the pin, compiler and flags. A worktree without its own `.oracle/src-<pin>` uses the
   main checkout's copy.
2. The harness loads `opts.k2d` the same way `classify.cc` `load_index` does: a zeroed `IndexOptions`
   struct overwritten with the file's raw bytes. It reads the input with upstream's `FastReader`
   (`PrimeStream`/`LoadBlock`/`Parse`, 8 MiB blocks), which is the reader `classify` uses at the pin.
   For every record, and for each mate file separately, it writes the `(minimizer, is_ambiguous())`
   pairs from `NextMinimizer()` to stdout. The stream format is `K2MMDMP1`, documented in
   `internal/mmscan/mmdump`.
3. `bin/k2probe equiv-scan` runs the harness, reads the stream and does three checks:
   - It reads `opts.k2d` itself and compares the fields with what the harness used.
   - It re-reads the FASTQ with a small Go reader, and checks that every ID and base string matches
     what `FastReader` produced.
   - It rescans every record with `internal/mmscan` and requires the values, the ambiguity flags
     and the stream lengths to be identical.

   On a mismatch it prints the file, the read number and ID, the interval, the minimizer index and
   both values, then exits 1.

Cases:
- **Viral `opts.k2d`** over each read set present. The read sets are `SRR062634_200000` (human WGS)
  and `SRR5935746_200000` (HMP2 human gut metagenome); override them with `G0B_SCAN_READS`.
- **Standard-8 `opts.k2d`**, if it is present.
- **Synthetic option variants** on SRR062634, which exercise scanner paths that the Viral options
  don't reach: `-r` (sub-intervals via `LoadSequence(seq, start, finish)`), `-R 0` (pre-2.0.8
  reverse complement), `k == l`, other k/l and masks, `k = 64`, and protein (`-P`, which feeds the
  bases unchanged as residues). These variants are coverage checks only. They are not database
  configurations.

**Inputs:** the pinned upstream sources (`scripts/oracle-build.sh`), Homebrew gcc on macOS,
`.cache/db/k2_viral_20260626` (`scripts/fetch-db.sh`), and the read sets
(`scripts/fetch-reads.sh <run> 200000`).

**Outputs:** `results/g0b/scan-<UTC date>/summary.txt` (commit, pin, harness build, DB and read
provenance, one line per case) and `scan.log` (commands and full output). Nothing large is written.
The dump streams over a pipe.

**Failure looks like:** a non-zero exit, `failures N` with N > 0 in `summary.txt`, and a
`k2probe: MISMATCH ...` or `k2probe: opts mismatch ...` line in `scan.log`.

**Unit tests** (`go test ./internal/mmscan`) need no data. They check golden streams in
`internal/mmscan/testdata/` that upstream's scanner produced from synthetic sequences only, a
brute-force reference on clean DNA, and zero allocations. Regenerate the golden streams with
`go test ./internal/mmscan -run TestGolden -update -mm-dump=<abs path to .oracle/harness/mm_dump>`.
