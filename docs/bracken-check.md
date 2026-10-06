# make bracken-check

**What:** a spot-check (issue #19) that Bracken, the usual downstream consumer of `--report`,
produces the same output from our report as from upstream's. For each sample, upstream's
`kraken2` wrapper at the pin and our `bin/aws-kraken2` run with identical arguments
(`--db <Standard-8> --threads 8 --paired --report kraken.report --output kraken.out R1 R2`).
Each side's directory is the working directory, so relative paths are identical on both sides.
Then Bracken's `est_abundance.py` runs on each side's report at levels `S` and `G`, with
`-r 100` (the `database100mers.kmer_distrib` that ships with the DB) and `-t 10`, which is
Bracken's own default. It writes `-o` (the abundance table) and `--out-report` (the
Bracken-adjusted kraken report).

These files are byte-compared between the two sides:
- the kraken `--report`, `--output` and exit status;
- per level, Bracken's `-o` table, its `--out-report`, its stdout and its stderr. The stdout is
  compared without the `PROGRAM START TIME` / `PROGRAM END TIME` lines, which hold wall-clock
  times.

Bracken is deterministic for a given report, so this check adds nothing new to Law 1 whenever the
reports are identical (which `make oracle` already checks). What it does is show the property
end to end, with the real consumer, on the inputs people actually feed it.

**Pins:**
- Bracken: `jenniferlu717/Bracken` tag `v3.1`, commit
  `cfeac04b6445c44c3825866683a6fdd18746cb58`. This is set in the script, which checks that the
  tag resolves to that commit and that the checkout is clean. It is cloned into this checkout's
  `.cache/bracken-src`.
- Bracken's `bracken` wrapper calls `python`, so the script calls `est_abundance.py` directly
  with `$BRACKEN_PYTHON` (default `python3`), using the same arguments the wrapper passes. The
  manifest records the Python version and path, and the sha256 of `est_abundance.py`.
- Upstream: the pin from `scripts/pin.env`. The full SHA and `git describe` are taken from the
  oracle build's `BUILD` file.

**Inputs:**
- `.oracle/<pin>/` (built by `scripts/oracle-build.sh` if missing).
- `.cache/db/k2_standard_08_GB_20260626` (`scripts/fetch-db.sh standard8`).
- Reads `.cache/reads/{ERR478965,SRR062634}_200000_{1,2}.fq` (fetched by `scripts/fetch-reads.sh`
  if missing). ERR478965 is the gut sample: trimmed reads, up to 100 bp. SRR062634 has 100 bp
  reads.

All paths come from the main checkout (`scripts/paths.sh`).

**Usage:** `make bracken-check`. Env: `BRACKEN_THREADS` (default 8), `BRACKEN_PYTHON`
(default `python3`), and `DECOMP_BIN` (as for `make oracle`). A local run is acceptable for this
spot-check; the manifest records the host and whether it is the canonical Linux aarch64 platform.
Commit first so that the manifest says `dirty: false`.

**Outputs:** `results/g1/bracken-<UTC ts>-<short sha>/` containing:
- `manifest.json`: result; commit and dirty flag; upstream pin and describe; Bracken
  repo/tag/commit/describe, Python version, `-r`/`-t`/levels; DB dir, SOURCE and ETag, and the
  kmer_distrib sha256; reads SOURCE; host (hostname, OS, arch, model); start and stop times;
  comparison counts.
- `cases.tsv`: one row per byte comparison, with sizes, both sha256 values and `identical`.
- `bracken.tsv`: per sample and level, from upstream's Bracken stdout: rows in the table, taxa at
  the level, how many are above the threshold, and reads redistributed. This is the resolution:
  a level where Bracken redistributed nothing could not have disagreed. The script fails a
  sample/level with fewer than 2 rows or with 0 reads distributed, and the summary flags any
  level with fewer than 10 taxa above the threshold as low resolution.
- `summary.md`: generated from the files above.
- `commands.txt` and `run.log`.
- `outputs/`: upstream's Bracken files and kraken report (both sides' files when anything
  differs).

The kraken `--output` files are kept under `.cache/bracken/<ts>/`.

**Failure looks like:** a non-zero exit, `"result": "FAIL"`, a `no` in `cases.tsv`, or `FAIL`
in `run.log`. Any difference is a defect (Law 1).
