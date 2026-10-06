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
3. **Variants.** Three variants of the real reads are made with `awk` under
   `.cache/oracle/<ts>/variants/`. Their sha256 go into the manifest.
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
| plain and gzip | gzip auto-detected (`*.fq.gz`) across samples and options, plus `--gzip-compressed` given explicitly |
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
| controls | two cases add one option on our side only (`--confidence 0.05`, `--minimum-hit-groups 3`). They must come out different, which shows the comparison is not blind. |

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
`make oracle DB=viral` on `ubuntu-24.04-arm`. `runs/g1-oracle-standard8.json` runs
`DB=standard8` on Graviton through `make run`.

**Failure looks like:**
- a non-zero exit with `oracle: FAILED`;
- `summary.md` lists the differing cases, the unexpected upstream exits, any control the
  comparison did not flag, and any failed coverage check;
- `run.log` shows `DIFF <db> <case> <kind>:` followed by the first differing lines.

Timings in the summary are informational. They come from one run each on a warm page cache, so
they are not the baseline (Law 2).
