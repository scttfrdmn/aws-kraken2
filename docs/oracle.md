# make oracle (scripts/oracle.sh)

**What:** this target checks Law 1 end to end. Each case runs the same command twice:
- once through upstream's own `kraken2` wrapper, built at the pin;
- once through our `bin/aws-kraken2`.

Both runs get identical arguments, the same real reads and the same real database. The target
then byte-compares, with `cmp`:
- `--output`;
- `--report`;
- the classified and unclassified files (both mates when paired);
- standard output;
- the exit status.

Any difference is a defect, and so is any upstream exit status other than the one the case
expects. Either makes the target exit non-zero.

```
make oracle                 # DB=viral (what CI runs)
make oracle DB=standard8    # Standard-8 (8 GB; capped, so the subthreshold skip path runs)
make oracle DB=all          # both, one results directory each
```

| env | effect |
|---|---|
| `ORACLE_THREADS` | the multi-thread count. The default is 8; the single-thread cases always use 1. |
| `ORACLE_CASES` | a regex that limits the run to matching case names. For development only: the manifest and summary both say the matrix was filtered, and failed coverage checks do not fail a filtered run. |
| `DECOMP_BIN` | a directory to put first on `PATH` for the wrapper's `gzip -dc`. The default is `/tmp/gnugzip/inst/bin` if present, else the system gzip. The canonical platform's is GNU gzip. |
| `ORACLE_KEEP=1` | keep every case's outputs. By default only failing cases keep theirs. |

## What it does

1. **Builds.**
   - `scripts/oracle-build.sh` builds upstream at the pin into the shared `.oracle/<pin>/`, if
     that is not already there. It uses upstream's own install script, the system `g++` with
     OpenMP on Linux, and Homebrew `g++` on macOS.
   - `make build` builds our binary.
2. **Inputs.**
   - `scripts/fetch-reads.sh` fetches any of the three samples that is missing.
   - `scripts/fetch-db.sh` fetches the selected database if it is missing.
   - Both use the shared `.cache/`; see [harness.md](harness.md#shared-resources-scriptspathssh-internaloracletest).
3. **Variants.** Variants of the real reads (table below) are made with `awk`, `gzip` and
   `bzip2` under `.cache/oracle/<ts>/variants/`. Their sha256 go into the manifest.
4. **Cases.** Every case is run on both sides, with the comparisons above.
5. **Results.** The run writes `results/g1/oracle-<db>-<UTC timestamp>/`.

## Inputs

Real public reads only (Law 3), 200,000 records per mate:

| label | run | what |
|---|---|---|
| S1 | SRR062634 | 1000 Genomes human WGS, 100 bp |
| S2 | ERR478965 | trimmed reads, 45 to 94 bp |
| S3 | SRR28305653 | NovaSeq, 150 bp |

None of the raw samples has a mate shorter than k, so variants cover the paths they
never reach:

| variant | made from | change | covers |
|---|---|---|---|
| `slash` | S1 | the mate number is moved into the identifier (`ID/1 comment`) | paired `--output` trims `/1` and `/2`; the sequence outputs keep them; single-end does not trim |
| `short` | S2 | every 5th mate 1 is cut to 20 bases, every 3rd mate 2 to 30, every 13th of both to 0 | the empty hit list `0:0` (single-end), and hit lists ending at, or consisting only of, the mate border `\|:\|` (paired); the empty-record path |
| `mates` | S2 | the last 10 records of mate 2 are removed | unequal mate files: upstream writes every pair it can, then exits 65 without the report |
| `empty` | none | empty files | no input: upstream opens no output until an input holds data |
| `fasta` | S1 | FASTA, one line per sequence | FASTA input; FASTA sequence outputs |
| `fastaw` | S3 | FASTA wrapped at 60 columns | multi-line FASTA records |
| `bz` | S2 | bzip2-compressed | bzip2 input, auto-detected and with `--bzip2-compressed` |

**Databases:**
- **Viral** has `minimum_acceptable_hash_value` 0.
- **Standard-8** is capped at `0xed805142634b1800`, so most minimizers fall below the threshold
  and the skip path runs on every read.

Both databases run the same matrix.

## The matrix (per database)

Every case gets `--db` and `--threads $ORACLE_THREADS`. The case table is at the top of
`scripts/oracle.sh`. Not every option runs on every sample. The design puts each option on at
least one sample, and the main options on more than one sample, layout or compression:

| dimension | cases |
|---|---|
| single-end and paired | every sample, both layouts |
| input formats | plain FASTQ; gzip auto-detected (`*.fq.gz`) across samples and options, plus `--gzip-compressed` given explicitly; bzip2, auto-detected and with `--bzip2-compressed`; FASTA, single-line and wrapped |
| `--output` on standard output | no `--output` at all: S1 single-end with a report; S3 paired gzip with sequence outputs and `--threads 4` |
| database lookup and environment | `--db` by name through `KRAKEN2_DB_PATH` (with a nonexistent entry and an empty one first); `KRAKEN2_NUM_THREADS` in place of `--threads` |
| unwritable outputs | `--report` (upstream's ofstream is unchecked: exit 0, no report); single-end `--classified-out`/`--unclassified-out` (unchecked: exit 0, no files); paired ones and `--output` (checked: exit 1) |
| `--confidence` 0, 0.1, 0.5 | S1 paired (all three); S3 single-end 0.1; S2 paired gzip 0.5 |
| `--minimum-hit-groups` 1, 3, plus the default 2 | S1 paired 1 and 3; S2 single-end 3; S3 paired 2 given explicitly; the default everywhere else |
| `--quick` | S1 paired; `--quick --confidence 0.5`; S3 `--quick --minimum-hit-groups 1`; the `short` variant |
| reports | `--report` in most cases; `--report-zero-counts`; `--use-mpa-style`, alone and with zero counts; zero counts with `--confidence 0.1` |
| sequence outputs | `--classified-out`/`--unclassified-out` in the core, threads, quick, -Q, mmap and variant cases, with `#` when paired |
| `--use-names` | S1 paired; S3 single-end with `--confidence 0.5` |
| `--minimum-base-quality 20` | S1 single-end; S2 paired gzip; the `short` variant |
| `--memory-mapping` | S1 paired; S3 single-end with one thread |
| `--threads` 1 and 8 | single-thread cases on S1 paired, S3 single-end gzip, S3 with mmap; 8 elsewhere |
| several inputs in one run | `S1,S2` single-end and `S2,S3` paired gzip (outputs, stats and report span the files) |
| empty input | an empty file alone (no output file is created), with `--report-zero-counts` (percentages `nan`), and an empty pair before S1 (outputs open at the first input with data) |
| exit statuses | mates differ (65); paired `--classified-out` without `#` (65); `--confidence 1.5` (255); `--use-mpa-style` without `--report` (64); `--threads 0` (64) |
| controls | cases that add one option on our side only (`--confidence 0.05`, `--minimum-hit-groups 3`). Each must exit alike on both sides with at least one output file different, which shows the comparison is not blind. |

**Coverage checks** (Law 4: could the matrix have seen the effect?). These are computed from
upstream's own outputs and written to `checks.tsv`. A failed check fails the run:
- `se-short` has reads with an empty hit list (`0:0`);
- `pe-short` has pairs ending at the mate border (`|:|`), and pairs with nothing else;
- `pe-slash` `--output` IDs keep no `/1` or `/2`, while its sequence outputs do;
- `se-slash` keeps the suffix;
- `-Q 20` masked bases to `x` and changed `--output`;
- one thread on plain input gives the same `--output` as 8 threads on gzip input;
- `--memory-mapping` gives the same `--output` as loading into RAM;
- `--quick` changes `--output`.

`minimum_acceptable_hash_value` is recorded as well.

**Matrix integrity** (each fails the run):
- a case filter that matches no case;
- on an unfiltered run, fewer rows in `cases.tsv` than cases defined;
- when a case expects exit 0: a requested output missing on either side (standard output: empty),
  or an output the case expects to be absent (empty input, unwritable path) present on either side;
- any file in a case's directory that the case did not ask for, on either side;
- the manifest's `failed` flag, which is computed from all of the above and decides the exit
  status.

## Known, tracked divergence

`--report-minimizer-data` (issue #18) is not implemented: `aws-kraken2` refuses it with exit 64,
where upstream adds the minimizer columns to the report. The matrix does not exercise it. It is
the one wrapper option whose output is not under the oracle yet.

## Outputs

`results/g1/oracle-<db>-<UTC timestamp>/`. Every value in it is generated by the script, never
typed:
- `manifest.json` records:
  - our commit and the dirty flag (tracked or untracked changes outside `results/`);
  - the upstream pin, its build record, and the sha256 of upstream's `classify` and `kraken2`;
  - the compiler, the Go version and the sha256 of our binary;
  - the host OS, arch, kernel and model, and `canonical_platform`, which is true only on Linux
    aarch64. Darwin runs say "development evidence only";
  - the gzip version and path;
  - the database SOURCE, ETag and decoded `opts.k2d`;
  - the reads' SOURCE files and the variants' sha256;
  - the threads, the case filter, start/stop times, and the case, pass and failure counts.
- `cases.tsv` has one row per case:
  - the arguments, and the expected, upstream and our exit statuses;
  - whole-process seconds on both sides;
  - the sha256 of every output on both sides (`absent` for not produced, `-` for not
    requested);
  - `files_compared`, `identical`, `upstream_exit_ok`, `control` and `pass`;
  - `requested_outputs_ok` and `unexpected_files` (the integrity checks above);
  - `stderr_same`, which is informational. stderr is not under Law 1; timings, program names
    and output file names are removed before comparing;
  - each side's classification time, as reported on its stderr.
- `checks.tsv` holds the coverage checks.
- `summary.md` holds the counts, all derived from `cases.tsv` and `checks.tsv`.
- `run.log` holds every command, and the first differing lines (`cmp`, then `diff | head`) of
  any difference.

The outputs themselves go to `.cache/oracle/<ts>/<db>/<case>/`, which is not committed. A
passing case's large files are deleted.

**Canonical platform:** Linux aarch64 (C `char` is unsigned there, which decides `-Q` on bytes
≥ 0x80). Darwin runs are development evidence only, and the manifest says so. CI runs
`make oracle DB=viral` on `ubuntu-24.04-arm`; `runs/g1-oracle.json` runs `DB=all` on Graviton
through `make run`.

## Engine mode: make oracle-engine (#24)

```bash
make oracle-engine DB=viral|standard8|all              # NS="1 2 3 4 8", TRANSPORT=local
make oracle-engine DB=standard8 TRANSPORT=tcp          # each shard behind a loopback TCP server
make oracle-engine DB=viral NS="5 7" TAIL=254           # other shard counts, an explicit tail
```

Law 1 holds at every shard count. This mode runs the same matrix, but each case runs upstream
once and ours once per shard count N in `NS`, through the sharded engine
(`internal/engine`, enabled in `bin/aws-kraken2` by `AK2_ENGINE_N=N`,
`AK2_ENGINE_TRANSPORT`, `AK2_ENGINE_TAIL`; see `cmd/aws-kraken2/engine.go`). Every run is
compared with upstream's outputs as in plain mode, with the same exit-status, existence,
unexpected-file and control rules. Our outputs for N go to `<case>/n<N>/`.

- In-process: N shards in one process. Each holds its floor-cut slot range plus the tail and
  is loaded from the local `hash.k2d` with parallel ranged reads. Each input block's lookups are
  routed to the shards that own their home slots (`local`: direct calls; `tcp`: the length-prefixed
  TCP protocol over loopback, the same one nodes use). The worker that scanned the block then
  classifies it.
- **Tail.** The default is 302 cells, RODA v205's global longest run, which also bounds Viral
  (216) and Standard-8 (254) (`results/g0c/local-*/<db>/tails.tsv`). Whatever tail is given,
  every shard checks at load that it holds an empty cell at or after its last owned slot. A tail
  too short for the table is a load error (exit 1), never a wrong answer.
- Results: `results/g1/oracle-engine-<db>-<UTC>/`. `cases.tsv` has one row per case and N:
  `case` is `<case>@n<N>`, plus `engine_n`, `tail_probes` and `wrap_probes`. The manifest has
  `mode: engine` and an `engine` object (shard counts, transport, tail), and `cases_defined` =
  61 × the number of shard counts.
- **Resolution (Law 4).** The engine runs with `AK2_TIMINGS=1`; these lines are removed before
  the informational stderr comparison. `checks.tsv` adds, per N > 1, the number of real lookups
  whose probe ended in a shard's overlap tail (the lookups a shard without its tail would get
  wrong), and how many of them ended in the wrapped part of the last shard's tail. These rows
  are informational. Real reads reach a tail only rarely: in the runs at a6894c2, 15 to 17
  lookups per N > 2 on Viral and none at N = 2. On Standard-8, `tail_probes` is 0 at every N, so
  there the read-level oracle cannot show the tail path is correct at all. A generated
  `engine resolution` row in `checks.tsv` (and so in `summary.md`) states this from each run's own
  numbers. The evidence for the tail path is two tests, not the read matrix:
  - `TestRealDBBoundaries` (`internal/engine/realdb_test.go`, run by `make test` when the
    pinned databases are present) works on the real Viral and Standard-8 tables. It inverts
    fmix64 to build lookups whose home slots cover every cell of the run crossing each shard
    boundary, wrap included, both misses and hits. Their engine values must equal
    `chash.Table.Get` at N = 2, 3, 4, 5, 8 and 16, using the tightest tail G0c's definition
    allows (the same values as `results/g0c/local-*/<db>/tails.tsv`) and also the default.
    Some of these lookups must end in a tail.
  - The synthetic-table tests in `internal/engine` cover tails one cell short (refused), a probe
    ending exactly at a shard boundary, the wrap, and full tables.

## Canonical run (Linux aarch64, Graviton)

`runs/g1-oracle.json` runs `make oracle DB=all` (Viral and Standard-8) on a Graviton instance in
us-west-2 through `make run GATE=g1 SPEC=runs/g1-oracle.json` ([run.md](run.md)). It depends on
neither genome-idx nor ENA; every input comes from in-region copies in the results bucket.

Prerequisites, run once from a machine that has the fetched inputs:
- `make stage-db DB=viral` and `make stage-db DB=standard8` (`scripts/stage-db.sh`) copy
  `hash.k2d`, `opts.k2d`, `taxo.k2d` and `SOURCE` from `.cache/db/<name>/` to
  `s3://cookbook-942542972736-us-west-2/aws-kraken2/data/<name>/`. The pinned genome-idx objects
  are in us-east-1, so they cannot be declared for a us-west-2 run. `SOURCE` keeps the
  genome-idx origin and ETag.
- `make stage-reads` (`scripts/stage-reads.sh`) copies the read subsets
  (`<run>_200000_{1,2}.fq`, the `.fq.gz` copies and `<run>_200000.SOURCE` for SRR062634, ERR478965,
  SRR28305653, SRR5935746 and ERR598966; ERR598966 is G0c-b's environmental class) to `…/aws-kraken2/data/reads/`. It first checks every plain FASTQ,
  and what every gzip copy decompresses to, against the sha256 its SOURCE recorded when ENA served
  it.
- Both scripts store each object's sha256 as metadata and check it with head-object after the
  upload. Both are idempotent: an object whose metadata already matches is skipped.
- The launch commit must be on GitHub. The instance clones the short sha that ends the run ID.

On the instance:
1. **setup** installs g++, make, zlib, perl, jq, bzip2, GNU gzip, findutils and diffutils with
   dnf, clones the commit and installs Go at the version in `go.mod`. Each step stops the run on
   failure.
2. **fetch** stages both databases (one prefix each) and, one file at a time, only the read
   files the run declares (the prefix also holds SRR5935746 and ERR598966, which the oracle does not use), with
   `ak2_stage`. For every file, both its sha256 and the object's sha256 metadata must be 64 hex
   digits and equal, and the file non-empty. The plain FASTQs, and what their gzip copies
   decompress to, must also match their SOURCE. Only a verified database copy has
   its staging location appended to `SOURCE`. A failure stops the run before anything is built.
3. **build** runs `scripts/oracle-build.sh` and `make build`; either failing stops the run.
4. **oracle** runs `make oracle DB=all ORACLE_THREADS=8`, streaming its output into the run log.
5. **push** pushes with `ak2_push` only the result directories this run created (the paths
   `make oracle` prints as `results: <dir>`), plus the oracle's output. The exit status is
   the oracle's; if that is 0, a failed push makes it 1.

Every S3 request is counted with `ak2_req`. `make run` head-objects every declared file at
launch, and refuses the run if one is missing.

**IAM:** `resources.s3_read_write` names the data prefix, but spawn's grant is its full
read-write grant, and run.sh checks only the bucket. In practice the instance can read and write
the whole results bucket, not just read the prefix. The `aws` PATH shim limits which buckets the
CLI may touch, not what it may do inside an allowed one.

CI (`.github/workflows/ci.yml`) still fetches its reads from ENA with `scripts/fetch-reads.sh`.
The portal API call is retried by curl (ENA intermittently answers HTTP 500); each FASTQ stream
is retried as a whole pipeline, up to 5 times, until it yields the requested number of lines in
well-formed FASTQ (`@` header, `+` separator, quality as long as the sequence). The script fails
loudly, naming the URL, once the retries are spent.

**Failure looks like:**
- a non-zero exit with `oracle: FAILED`;
- `summary.md` lists the differing cases, the unexpected upstream exits, wrong output
  existence, unexpected files, any control the comparison did not flag, and any failed coverage
  check;
- `run.log` shows `DIFF <db> <case> <kind>:` followed by the first differing lines.

Timings in the summary are informational. They come from one run each on a warm page cache, so
they are not the baseline (Law 2).
