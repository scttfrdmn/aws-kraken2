# make g0b / make harness

**What:** G0b equivalence runs of the Go ports against upstream at the pin, on real reads and
real databases, locally (no AWS). `make harness` builds the C++ oracle harnesses; `make g0b`
rebuilds them and runs the steps end to end.

```
make g0b                 # all steps (scan, then hash)
make g0b G0B=hash        # one step (PART=... is accepted too)
G0B_DBS=viral make g0b   # restrict hash databases (default "viral standard8")
G0B_SCAN_READS="SRR062634_200000" make g0b G0B=scan   # scan read sets
G0B_RUN_ID=x make g0b    # results dir suffix (default: UTC time + short commit, as g0a)
```

| step | issue | compares |
|---|---|---|
| `hash` | #4 (G0b-1) | `internal/chash` vs upstream `CompactHashTable` (`compact_hash.h`) |
| `scan` | #5 (G0b-2) | `internal/mmscan` vs upstream `MinimizerScanner` (`mmscanner.cc`) |

Every step writes `results/g0b/<step>-<run-id>/manifest.json` with the commit, a dirty flag
(tracked or untracked changes outside `results/`), the invocation and its environment, the pin,
host, Go version, each database's source and ETag inline, the number of comparisons made,
start/stop and outcome. An existing results directory is never overwritten: the script refuses.

**Inputs:** the upstream checkout and the pinned databases and reads, from `make oracle`,
`scripts/fetch-db.sh` and `scripts/fetch-reads.sh`. Scripts find them in the main checkout
through git's common dir, so worktrees share them (`scripts/paths.sh`; override with
`K2_SHARED_ROOT`). A requested database whose download is incomplete (no `SOURCE` file), a
requested read set that is absent, an empty key population, or a step that made zero comparisons
is a failure, not a skip.

## Harnesses

Built by `scripts/harness-build.sh`; see [harness.md](harness.md). `hash` uses `chash_keys` and
`chash_dump` (both variants, `-v lp,dh`), `scan` uses `mm_dump`.

## Step `hash`

For each database:

1. `chash_keys opts.k2d ...` runs upstream's `MinimizerScanner`, configured from `opts.k2d` as
   classify does, over SRR062634 (both mates). Three populations, in separate files:
   `keys-real.u64`, every non-ambiguous minimizer classify would look up (at or above
   `minimum_acceptable_hash_value`; consecutive repeats kept); `keys-subthreshold.u64`, the
   real minimizers that filter drops (non-empty only for downsampled databases such as
   Standard-8; `keys.txt` records the counts); `keys-random.u64`, as many uniform random uint64
   keys as `real` (splitmix64, fixed seed), a miss-heavy control. An empty population fails the
   run, except `subthreshold` on a database whose `minimum_acceptable_hash_value` is 0.
   The subthreshold set checks lookups and probe counts on keys classify never asks for; it is
   **not** a false-positive control (those keys were never inserted, so neither side can say
   whether a hit would be "false").
2. `chash_dump{,.dh} hash.k2d` looks every key up with upstream's `Get`, `GetBatch` and
   `FindIndex`, writing value and probe count (cells examined) per key.
3. `k2probe equiv-hash` looks the same keys up in Go and compares per key:
   - linear mode, RAM load and mmap load, vs the shipped build: **acceptance, 0 mismatches**;
   - double mode vs the `.dh` build: checks the Double port, must be 0 mismatches;
   - double mode vs the shipped build, counted (`-stop=false`): evidence for which probe mode
     the database was built with.

**Outputs:** `results/g0b/chash-<run-id>/`: `manifest.json`, `summary.md`, `commands.txt`,
`harness-<bin>.BUILD`, and per database `db-SOURCE.txt`, `keys.txt` (scanner counts),
`upstream*-<pop>.txt` (upstream counts and timings), `go-*.{txt,json}` (comparison, probe
histograms for hits and misses, Go timings). Key and lookup dumps go to `.cache/g0b/<db>/`
and are not committed.

**Failure looks like:** `k2probe equiv-hash` stops at the first mismatch and prints the key,
its hash, home cell, compacted key, both answers and the cells along the probe path. The
script records a `FAIL:` line, keeps going with the other checks, and exits non-zero with
`"failed": 1` in the manifest. Timings are single-thread, warm page cache, on the machine named
in the manifest: they describe this probe, not the baseline (Law 2).

## Step `scan`

1. `scripts/harness-build.sh mm_dump` builds `upstream/mm_dump.cc` (see above).
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

**Outputs:** `results/g0b/scan-<run-id>/manifest.json`, `summary.txt` (commit, pin, harness
build, DB and read provenance, one line per case) and `scan.log` (invocation, `G0B_SCAN_READS`,
commands and full output). Nothing large is written.
The dump streams over a pipe.

**Failure looks like:** a non-zero exit, `failures N` with N > 0 in `summary.txt`, and a
`k2probe: MISMATCH ...` or `k2probe: opts mismatch ...` line in `scan.log`.

**Unit tests** (`go test ./internal/mmscan`) need no data. They check golden streams in
`internal/mmscan/testdata/` (a missing golden stream is a failure, not a skip) that upstream's scanner produced from synthetic sequences only, a
brute-force reference on clean DNA, and zero allocations. Regenerate the golden streams with
`go test ./internal/mmscan -run TestGolden -update $(scripts/harness-build.sh mm_dump)`.
