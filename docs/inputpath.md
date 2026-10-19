# G2 input-path sweep (I0–I4, #90)

## Pre-flight and inputs

This section covers the sweep's no-spend checks and its derived test inputs. Both come before
any AWS session.

```
make inputpath-preflight                                   # PART=local: Viral DB, S1, what CI runs
make inputpath-prep                                        # BGZF re-encodes and rapidgzip indexes, uploaded and tagged
make inputpath-preflight PART=inputs DB=standard8          # the sweep's own inputs (inputs.tsv); I0-I4 on Standard-8
```

Scripts: `scripts/inputpath/preflight.sh`, `prep.sh`, and `lib.sh`, which holds the tool pins and
helpers. Inputs: `scripts/inputpath/samples.tsv`, the chosen samples. Output:
`scripts/inputpath/inputs.tsv`, which the harness reads.

### The inputs

| role | sample | why |
|---|---|---|
| pe | SRR062634, the first 8,000,000 pairs (`aws-kraken2/data/reads/SRR062634_8000000_{1,2}.fq[.gz]`) | the #6 host-dominated human WGS class. Already staged in the project bucket (no new egress), and it is G2's #21/#22 input. 630 MB / 626 MB gz, 2.09 GB FASTQ per mate. |
| se | **SRR4074269** (Scott, 2026-10-18), the whole run (`aws-kraken2/data/reads/SRR4074269.fastq[.gz]`) | none of the four #6 samples is single-end. PRJNA340216 (De Filippis et al., omnivore/vegetarian/vegan human gut), Illumina HiSeq 1500, SINGLE, WGS, 14,649,848 reads of 151 bp. 1.58 GB gz, 4.93 GB FASTQ. |

`make inputpath-stage-se [RUN=SRR4074269]` (`scripts/inputpath/stage-se.sh`) staged the
single-end sample from ENA:
- It records ENA's filereport in `results/inputpath/se/<RUN>/run.tsv` and `query.json`.
- It downloads the `.fastq.gz` over HTTPS into a fresh `/tmp` directory, in 8 ranged streams.
  Bytes and md5 must equal ENA's (`da9981e47ee7137d3c6e4f2f1716a492`, 1,578,815,219 B; 305 s on
  the laptop).
- It `gzip -dc`s the file to the plain FASTQ, which is I0's input.
- It uploads both under `aws-kraken2/data/reads/` with `sha256` metadata (and `md5` on the
  `.gz`), checks them with head-object, tags them, and appends to `staged.tsv`.

`STAGE_KEEP=1` keeps the download, and `INPUTPATH_SRC_DIR=<it>` points `make inputpath-prep`
and `PART=inputs` at it, so nothing is downloaded twice.

### `inputs.tsv`

The header is fixed: `role accession mate s3_key sha256 kind source_sha256`.
- `kind` is one of:
  - `fastq` — plain FASTQ, used by I0;
  - `gz` — I1 and I2;
  - `bgzf` — I4;
  - `index` — the rapidgzip index of the `gz` row, used by I3.
- `source_sha256`:
  - for `fastq`, `gz` and `bgzf`, it is the sha256 of the FASTQ the object decodes to (for
    `fastq`, its own sha256);
  - for `index`, it is the sha256 of the `.gz` it indexes.
- The identity check compares every decode against it.
- A single-end sample's rows have mate `1`.

### The rules the harness must keep

- **No `--gzip-compressed` in I2–I4.** The wrapper would run `gzip -dc /dev/fd/N` on an
  already-decoded stream.
  - The negative control shows this fails silently: exit 0, no `--output`, 0 sequences, and only
    a gzip message on stderr (Apple gzip on the laptop: "/dev/fd/63 is not a regular file"; the
    run's `runs.tsv` and stderr files record the message on each host).
  - I1 passes the `.gz` and lets the wrapper auto-detect it. Auto-detection reads the first
    file's magic, and only for regular files.
  - `preflight.sh` asserts the rule on every command it builds. It also scans the sweep's files
    (`scripts/inputpath/*` apart from its own three, `scripts/g2/*inputpath*`, `runs/*inputpath*`)
    and fails on any `--gzip-compressed` line that mentions rapidgzip, `/dev/fd`, `<(` or I2–I4.
- **Never trust a decode without comparing it to `gzip -dc`** (rapidgzip 0.14.5 crashed 2 times
  in about 1,553 decodes on Graviton4; #89).
  - Every rapidgzip decode's sha256 must equal its row's `source_sha256` (for an index, the
    `source_sha256` of its `.gz`), and its exit status must be 0.
  - A crash (exit 139) or a mismatch is recorded and the run is not used.
- **I3's index:** built by `rapidgzip -d -c -P 16 --chunk-size 4096 --index-format indexed_gzip
  --export-index`.
  - The seek-point spacing depends on `-P`: indexes exported at -P 1, 4 and 16 differ. At -P 16
    the export is deterministic (two exports gave the same sha256).
  - At `-P 1` rapidgzip ignores the index ("The index only has an effect for parallel
    decoding"), so I3 at p = 1 is I2 at p = 1.
- **ISA-L: none in the aarch64 wheel.** The pinned manylinux aarch64 wheels (cp39–cp313, the
  wheels lever.sh installs on Graviton) and the macOS arm64 wheel do **not** contain ISA-L.
  - Evidence:
    - no `isal_inflate_init` symbol and no `github.com/intel/isa-l` attribution in the extension;
    - `rapidgzip -v` reports 0 s "decoding with ISA-L";
    - the pinned cp39 x86_64 wheel does contain it, which is the detector's positive control.
  - So on Graviton the pinned wheel decodes with its own inflate and zlib.
  - **The ISA-L arm** (Scott, 2026-10-18) is rapidgzip 0.14.5 built from source with ISA-L and
    with rpmalloc off. The Graviton crash (#89) is in 0.14.5's bundled rpmalloc on aarch64. The
    arm will use the shared build script `scripts/g3/rg-build.sh`, which comes in a separate PR.
    These targets do not build it.
  - Every decode of that build goes through the same identity check, and its manifest records
    the build.

### `make inputpath-preflight` (PART=local)

PART=local uses the Viral DB and the G1 oracle's sample S1 (`SRR062634_200000`), paired and
single-end, at `--threads 8`. It builds its own BGZF and index of S1 under `/tmp`. Checks
(`checks.tsv`, one row each):
- `source`: S1's FASTQ equals its SOURCE sha256.
- `identity`: for each mate's `.gz`, its BGZF, and its `.gz` with the index:
  - `gzip -dc` and rapidgzip at -P 1, 2, 4, 8 and 16 all give the FASTQ's sha256, with exit 0;
  - the export pass gives it too.
- `bgzf`: the re-encode is BGZF (the `BC` extra field).
- `isal`: recorded for this host's wheel and every pinned aarch64 wheel. The x86_64 positive
  control is checked.
- `gzflag`: the scan above.
- `exit`, `decoders`, `arms`, `devfd`: the upstream wrapper at the pin runs I0 (plain files),
  then the other arms, which are compared with I0:
  - I1: the `.gz`, auto-detected;
  - I1f: the `.gz` with `--gzip-compressed`;
  - devfd: `<(gzip -dc)` for both mates;
  - I2: `<(rapidgzip -P p)`;
  - I3: `<(rapidgzip -P p --import-index)`;
  - I4: `<(rapidgzip -P p)` on the BGZF, at every p.

  Every arm must exit 0, every decoder behind `<(...)` must exit 0, and `--output` and
  `--report` must be byte-identical to I0's.
- `neg-control`: `--gzip-compressed` on the `/dev/fd` paths must give a different `--output`
  (Law 4: the comparison can see a wrong input path).
- `g1`: I0's `--output` and `--report` equal the latest passing, unfiltered G1 oracle record at
  the pin for the same input (`results/g1/oracle-viral-*`, cases `pe-default-gz-S1` and
  `se-default-S1`).

It records the results in `results/inputpath/preflight-local-<UTC>-<commit>/`: `manifest.json`,
`checks.tsv`, `runs.tsv` (each kraken2 run's command, exit status, decoder exit statuses,
seconds, sequences and output hashes), per-run stderr, and `run.log`, which is streamed as it
goes. It takes about 30 s on the laptop. CI runs it after `make oracle-cohort`.

### `make inputpath-prep`

1. **Gate.** Refuses to upload without a passing `preflight-local` record whose `checks_sha256`
   (lib.sh, preflight.sh and lever.sh) equals the current scripts'.
2. **Checks first.** Then checks the bucket's region (us-west-2) and Payer, the instance region
   when on EC2, and that at least 60 GB is free.
3. **Per `.gz` in `samples.tsv`:**
   - Uses `.cache/reads` if the sha256 equals the object's metadata, else downloads into a fresh
     `/tmp` directory.
   - Requires `gzip -dc` to equal the staged FASTQ object's sha256.
   - Builds the BGZF: `gzip -dc | bgzip -l 6 -@ 8 -c`. Checks that it is BGZF (header and EOF
     block), and that `gzip -dc`, `bgzip -dc` and rapidgzip at every -P give the FASTQ.
   - Exports the index and checks the export pass and every -P with and without the index.
4. **Upload.** Only when every check passed: uploads to `aws-kraken2/data/inputpath/` with
   `sha256` and `source-sha256` metadata, checks with head-object, and tags (`project`, `kind=data`).
5. **Record.** Writes `inputs.tsv` and `results/inputpath/prep-<UTC>-<commit>/`: `manifest.json`
   (tools, commands, objects with ETag and version ID), `checks.tsv`, `commands.txt` and `run.log`.

Options:
- `INPUTPATH_DRY=1` builds and checks without uploading.
- `INPUTPATH_KEEP=1` keeps the work directory, to pass to PART=inputs as `INPUTPATH_DIR`.

The prep is reproducible. A second run on 2026-10-18 rebuilt byte-identical BGZF and index
files, found them present and uploaded nothing (`results/inputpath/prep-20261018T191743Z-*`).

The inputs are small: 2.84 GB gz in all. The laptop already held the pe sample, and the se
sample came from ENA through `make inputpath-stage-se`. So the prep ran on the laptop with no S3
download. On a node it runs as is: it needs a C compiler, make,
zlib headers and python 3.9–3.13.

### `make inputpath-preflight PART=inputs [DB=viral|standard8]`

This is the node's first step of the session, and it can also run on the laptop.
1. Every `inputs.tsv` object is located (`INPUTPATH_DIR`, `INPUTPATH_SRC_DIR`, `.cache/reads`,
   else downloaded) and its sha256 is checked.
2. Every `gz` and `bgzf` gets the identity check, and every `index` gets it with its `.gz`.
3. With `DB`, I0–I4 run (at `PREFLIGHT_PS`, default 4) for the pe and se roles.

No G1 or G2 Standard-8 oracle exists for these inputs. G2's SRR062634_8000000 runs used full RODA
v205. So PART=inputs records I0's hashes as the reference (`g1_reference` in the manifest), and the
node's I0 must equal them. For S1, the Standard-8 G1 record (`results/g1/oracle-standard8-*`) is
checked the same way as in PART=local.

The laptop's Standard-8 I0 references (upstream at the pin, `--threads 8`), from
`results/inputpath/preflight-inputs-20261018T224922Z-89e0340/`:

| role | `--output` sha256 | `--report` sha256 |
|---|---|---|
| pe SRR062634_8000000 | `3c4d7d2157f4a4ea79dc51378fb0c7434769801ae95e5d0d5f6e65aa87a659bb` | `13ae4bd4ecb24c27309b6199be2afaeec0375a1e1bb62b36e217ae7cefb33bed` |
| se SRR4074269 | `6020d09e5a1548ea82f5d4bf84f44bfcf2f40a7c93dd8f42652a8d20c693d9cb` | `49c275ff3b9a5486ae42adcb2f8199c462dd0a4533957b4de99855af02124995` |

In that run, I1–I4 (at -P 4) equalled I0 for both roles.

### Pins

| tool | pin | where |
|---|---|---|
| bgzip | htslib 1.24, tarball sha256 `28a8de19…77de` (equal to GitHub's asset digest), zlib only (`--without-libdeflate`), level 6 | `lib.sh` |
| rapidgzip | 0.14.5, PyPI wheels by sha256: lever.sh's manylinux list on nodes; `IP_RG_MACOS_HASHES` on the laptop | `scripts/g3/lever.sh`, `lib.sh` |
| upstream | `scripts/pin.env` | `scripts/oracle-build.sh` |

Tools go to `INPUTPATH_TOOLS` (default `/tmp/ak2-inputpath-tools`) and are reused when they match
the pins.

## The harness: `make inputpath`

**What:** one spawn session per instance family runs the whole I0–I4 matrix for one engine, on
one 64-vCPU instance, with Standard-8 resident. It measures how much of the classifier's wall
time is input decompression and parsing, and whether rapidgzip removes it (plan and decisions:
issue #90). Backed by `scripts/inputpath/` (`mkspec.sh` the generator, `inputpath.body.sh` the
body, `run_point.py` one instrumented point, `record.py` the point record, `pipesz.py` the pipe
wrapper, `inputs.py` the input list, `estimate.py` the time model, `tables.py` the table) and
`scripts/post/inputpath.sh`.

```bash
make inputpath FAMILY=c8g ENGINE=upstream          # writes runs/inputpath-c8g-upstream.json; prints the
                                                   # estimate, the cost bound and the make run command
make inputpath FAMILY=c8gn ENGINE=ours ARGS='THREADS="48 16"'   # a cut matrix (any KEY=VALUE of mkspec.sh)
make rehearse SPEC=runs/inputpath-c8g-upstream.json   # local, AL2023 containers (below)
make run GATE=inputpath SPEC=runs/inputpath-c8g-upstream.json   # Scott's call: commit and push first
make orphans
```

`make inputpath` launches nothing. With `LAUNCH=1` it runs `scripts/run.sh inputpath SPEC`, which
is the same as `make run`. It does this only when the spec is committed and unchanged, and
`inputs.tsv` is valid. The spec is generated, never edited by hand. Regenerate it after any
change to the body or to `inputs.tsv`.

`make inputpath-test` runs the self-tests of `record.py` (the status rules) and `inputs.py` (the
input list's rules). Both are also part of `make test`.

### Sessions

| family | type | on-demand $/h (truffle 0.57.1) | TTL | cost_limit |
|---|---|---|---|---|
| c8g | c8g.16xlarge | 2.55232 | 117 min | $4.98 |
| c9g | c9g.16xlarge | 2.78208 | 107 min | $4.97 |
| c8gn | c8gn.16xlarge | 3.792 | 79 min | $5.00 |

Each type is 64 vCPU, 128 GiB, arm64, with no instance store. The TTL is the longest whole
minute, at most 240 (Scott: up to 4 h), whose cost_limit is at most $5 (Scott: per run). Here
cost_limit is TTL × price + $0.005, to the cent, which is cost_check's rule. Both engines use the
same TTL. The AZ is us-west-2b.

Both arms use the AMI that `make run` uses today: spawn's auto-selection, recorded as `.ami` in
the manifest and in the body's `host` line.

### The body

1. **Setup.** dnf (including sysstat and GNU time), then the clone at the launch commit.
   `inputs.tsv` is checked first, so a missing or incomplete list fails before any build or stage.
   Then the host line, and the engine build in the background:
   - upstream: `scripts/oracle-build.sh` at the pin;
   - ours: `make build`.

   rapidgzip comes from lever.sh's `lv__rg_ensure`: 0.14.5, pip `--require-hashes`. Its
   `--version`, `--help` and `--oss-attributions` go to `out/rapidgzip-info.txt`, with ISA-L
   evidence grepped from them.
2. **Stage, into tmpfs.**
   - Our Standard-8 copy, `aws-kraken2/data/k2_standard_08_GB_20260626`, goes to `/mnt/ip-db`
     (`huge=never`), with each file checked against its sha256 metadata.
   - For upstream, a copy also goes to `/mnt/ip-db-huge` (`huge=always`), checked with `cmp`.
   - Every `inputs.tsv` object goes to `/mnt/ip-in`, checked against its row's sha256.
   - The FASTQ is derived with `gzip -dc`. That sha256 is the reference every decode must equal.
   - The BGZF's `gzip -dc` must equal it too. The `source_sha256` rules are under "Inputs".
3. **`ak2_drop_caches`** runs once. If it fails, the run ends with exit 95 (the preamble's rule).
   Then come the points. The DB is resident in RAM. Each classifier run maps it from tmpfs.
   Upstream's default load is `mmap` plus `LoadFile`. Ours reads the table into its heap. Every
   point after the warm-up is warm.

### The matrix (per sample; the smaller FASTQ first)

| set | points | arm, parameters |
|---|---|---|
| warm-up | 1 | I0 at the highest threads: the sample's Law 1 reference, `status: skipped` |
| I0 | threads | the FASTQ on tmpfs |
| THP contrast (upstream) | threads | I0 at `never` (the main points run at `always`) |
| I2 | p × threads | `<(pipesz 1 MiB rapidgzip -d -c -P p --chunk-size 4096 mate.gz)` per mate, no `--gzip-compressed` |
| best p | — | per sample and threads, from rep 1's I2 points (rule below), one `select` line each |
| I3 | threads | I2 at the best p, `--import-index mate.index` |
| I4 | threads | I2 at the best p on `mate.bgzf` |
| chunk | 2 × threads | I2 at the best p, `--chunk-size` 8192 and 16384 KiB. The 4 MiB point is I2's own |
| pipe contrast | threads | I2 at the best p with the pipe left at its default (`pipesz default`) |
| I1 | threads (ours: 2 × threads) | `--gzip-compressed mate.gz`: upstream's wrapper `gzip -dc`; ours as `AK2_DECOMPRESS=pipe` and in process |

The defaults are threads {48, 32, 16} (highest first; {48, 16} on c8gn, whose TTL is 79 min),
p {16, 8, 4, 2} and REPS 2. With them, upstream has 36 points per sample per rep (24 on c8gn) and
ours also has 36 (no THP contrast, two I1 sets).
Rep 1 of everything runs first. Rep 2 runs rep 1's list in reverse and reuses rep 1's best p.

**Best p (the rule).** Take rep 1's I2 points of the PyPI build at chunk 4 MiB, the main pipe
size and the main THP, with status `ok` and identity `ok`. The best p is the smallest p whose `wall_s` is within 1% of the minimum
`wall_s`. If there is none, I3, I4, chunk and pipe at those threads are skipped (`no-best-p`).

**A second rapidgzip build** (off by default; its use waits for #97). It adds I2, I3 and I4 at the
best p with that build, per threads (`harness.decomp` `rapidgzip-2`). Its decodes take the same
identity checks, and every one of its points records its `rapidgzip {version, build, isal,
build_detail}`. Exactly one of:
- `ARGS="RG2_WHEEL=<https url of a .whl>@<sha256>"`: a pinned wheel. It is downloaded, checked
  against the sha256, and installed with `pip --require-hashes` into its own venv, as lever.sh
  installs the first. The candidate is the rapidgzip 0.16.0 cp39 manylinux aarch64 wheel, which
  carries ISA-L (#97: 0.14.5 cannot build ISA-L on aarch64; its setup.py builds ISA-L only on
  x86_64). Its use waits for #97's verdict on whether 0.16.0 is crash-free on Graviton:

  ```
  RG2_WHEEL=https://files.pythonhosted.org/packages/46/5e/bfd0ba68015806de0959c6514a61b162548014c550a30e83be81943878c7/rapidgzip-0.16.0-cp39-cp39-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl@2c3d75cb314b6dc28cf8fa238ff56f5ffae142af581f531fc674229184386f1d
  ```
- `ARGS="RG2_SCRIPT=<script in the tree>"`: a source build. The body runs the script with a work
  dir and takes the binary path from its last stdout line.

Its version is read from `--version`, and its ISA-L verdict comes from the same detector (an
`isal` line). Rehearsal case W installs the 0.16.0 wheel this way and runs it on a small matrix.

**Threads** count against the same 64 vCPUs. Each record carries `decoder_threads` (p × mates),
`total_threads` and `oversubscribed` (more than nproc). Oversubscribed points are kept, not
pruned. For ours, `fanout` = threads.

**THP.** `transparent_hugepage/enabled` is set before each point and read back (`thp`). A write
that does not take ends the run. The boot value is restored at the end (`summary.thp_restored`).
At the pin, upstream's table is never anonymous memory, even without `--memory-mapping`. It is
`mmap(MAP_PRIVATE)` of hash.k2d, pre-faulted by `LoadFile`. So the `enabled` knob alone cannot put
the table on 2 MiB pages. THP is applied in two places:
- `always` reads the table from a `huge=always` tmpfs and sets `enabled=always`;
- `never` reads it from a `huge=never` tmpfs and sets `enabled=never`.

Each point records the classifier's `smaps_rollup` maxima (AnonHugePages, ShmemPmdMapped,
FilePmdMapped), so whether the pages really were huge is a measurement. Ours keeps its table on
the heap, so for ours `enabled` is the knob and the DB comes from `/mnt/ip-db`.

**The pipe.** `scripts/inputpath/pipesz.py` raises the process substitution's pipe, rapidgzip's
stdout, to 1 MiB with `F_SETPIPE_SZ`. It reads the size back with `F_GETPIPE_SZ`, writes it to the
point dir, and execs `/usr/bin/time … rapidgzip`. A size it cannot get fails the decode, so the
point is never measured at the wrong size. The record's `pipe_bytes` is the size actually got.
`/proc/sys/fs/pipe-max-size` is in the host line. Upstream's I1 pipes, its wrapper's `gzip -dc`,
stay at the default; changing them would need a code change.

### Identity and Law 1

- **Identity** (Scott, 2026-10-18; the 0.14.5 crashes are #89). Before a rapidgzip build and
  configuration (binary, args and file) is used in any point, it decodes the file to `sha256sum`.
  The result must equal the file's `gzip -dc` sha256.
  - A crash, a timeout (`ID_TIMEOUT`, 360 s) or a mismatch is an `identity` line with
    `ok: false`. It is retried once: #89 measured 0.14.5's rpmalloc race at about 0.25% of
    decodes on Graviton4, so one crash is not the configuration's verdict. Each attempt is its
    own line (`attempt` 1, 2).
  - Only when both attempts fail is every point that needs that configuration `skipped`
    (`skipped-identity`) and never run.
  - Inside a point, a decoder exiting non-zero, read from its GNU time record, makes the point
    `skipped` (`decode-crash`). It is listed and never used.
  - The point's `identity` object holds the check of every mate (the deciding attempt's sha256s
    joined in mate order, the worst exit, `ok` for all of them) and `mates[].attempts`.
- **Law 1 against upstream at the pin, before anything is measured.** Each sample's warm-up I0
  must equal #95's recorded reference: `g1_reference` in
  `results/inputpath/preflight-inputs-20261018T224922Z-89e0340/manifest.json` (`G1_REF`), the I0
  `--output` and `--report` sha256 of upstream at the pin on these inputs and Standard-8 (pe
  SRR062634_8000000, se SRR4074269; the table above). The file and its sha256 are a `g1-reference`
  line and `harness.g1_reference` in every record. A mismatch makes the warm-up `status: defect`
  (`law1-g1-mismatch`), streams a `defect` line, and ends the run (exit 1) before any other point.
  For ENGINE=ours this is the comparison with upstream; within the run the report only compares
  points with each other.
- **Law 1 within the run.** Every point's `--output` and `--report` sha256, and its sequence
  count, must equal the sample's warm-up I0. Otherwise the point is `status: defect` (`law1-mismatch`), with a
  `defect` line. A classifier that fails is also a defect (`classifier-failed`).
  `make inputpath-report` re-checks Law 1 against the I0 points.

### What one point measures (`run_point.py`)

`bash -c CMD`, in its own session, with:
- the classifier under `/usr/bin/time -f 'ak2time …' -o k2.time`;
- each decoder under its own `rg<mate>.time`.

The instruments:
- **`wall_s`**: exec to exit. It includes starting the decoders and the classifier's DB map.
- **`load_s`**: exec to `Loading database information... done.`.
- **`classify_s`**: the classifier's own `processed in`, the classification phase.
- **`classify_window`**: the same span in the pidstat CSV's time base.
- **`classify_reads_per_s`**: sequences × mates / classify_s.
- **`fastq_mb_per_s`**: the FASTQ bytes of all mates / classify_s. `harness.fq_mb_per_s_wall` is
  the same over wall.
- **`pidstat -t -u -r -h 1`** over the run. It is filtered to the session's processes and
  written as `out/pidstat/<id>.csv`, in the report's schema:
  `t_s,tgid,tid,command,role,cpu_pct` plus `proc_comm,comm,usr_pct,sys_pct,wait_pct,core,
  minflt_s,majflt_s,vsz_kb,rss_kb`.
  - rapidgzip and gzip threads carry their role.
  - The classifier's threads are `command kraken2:<comm>` with no role. Upstream has no dedicated
    reader thread: each OpenMP worker reads its 3 MB block under `omp critical(seqread)`. Ours'
    goroutines are not threads. So the report infers the reader as the busiest classifier thread
    and says so.
  - `harness.pidstat_summary` gives CPU seconds, threads and the busiest thread's mean %CPU per
    group: engine_main, engine_workers, rapidgzip, gzip, other.
- **Peak RSS**:
  - `peak_rss_kb.kraken2` from GNU time (the wrapper execs classify in the same pid);
  - `rapidgzip`, `rapidgzip_mate<n>` from theirs;
  - `gzip` from `/proc/<pid>/status` VmHWM, sampled at 2 Hz;
  - `harness.procs`: every process of the session, with VmHWM.
- **`--timeout`** (`POINT_TIMEOUT`, 900 s) kills the session. The point is `skipped`
  (`timeout`, censored).

### Inputs

The harness reads `scripts/inputpath/inputs.tsv`, written by `make inputpath-prep` ("Pre-flight
and inputs" above). `scripts/inputpath/inputs.py check` validates it on the node before anything
is built or staged:
- exactly one accession per role (pe/paired, se/single);
- one gz, one bgzf and one index row per role and mate;
- objects only in `aws-kraken2-942542972736-us-west-2`;
- 64-hex sha256s.

Every staged object must equal its row's sha256. The FASTQ is derived on the node with
`gzip -dc`, and a `fastq` row's sha256 must equal it; fastq rows are not staged. `source_sha256`
must be the FASTQ's sha256 (gz, fastq, bgzf) or the gz's (bgzf, index), or empty.

`make inputpath` adds every staged row's object to the spec's `AK2_DATASETS`, so `run.sh` records
its ETag in the manifest. It also sets `AK2_ACCESSIONS` from the accessions, and the body checks
that they are the same set.

### Where each field lives

`run.sh` writes `manifest.json`. The sweep's added fields are per point:

| plan field | where |
|---|---|
| arm, rapidgzip p, kraken2 `--threads` | `out/points.jsonl`: `arm`, `p`, `threads`; `tables/inputpath.tsv` |
| chunk size, pipe size, THP | `chunk_mib`, `pipe_bytes` (got; `harness.pipe_requested`), `thp` (read back; `harness.thp_requested`) |
| rapidgzip version, build, ISA-L | `rapidgzip {version, build: pypi\|source, isal}`; the `tool` and `isal` lines in `out/events.jsonl`; `out/rapidgzip-info.txt`; `out/lever.jsonl` (wheel and extension sha256) |
| Law 1 reference (upstream at the pin) | `harness.g1_reference {file, sha256, output_sha256, report_sha256}`; the `g1-reference` line |
| input object keys and sha256 | `input.mates[].s3_key`, `.sha256`, `.fastq_sha256`; the `input` lines; the manifest's `datasets` (ETag) |
| index hash (I3), BGZF hash (I4) | `index_sha256`, `bgzf_sha256` (mates space-separated, mate order); `input.mates[].index_sha256` |
| pidstat CSV path | `pidstat_csv` (`out/pidstat/<id>.csv`) |
| peak RSS per process | `peak_rss_kb`; `harness.procs` |
| output and report sha256 | `output_sha256`, `report_sha256`; `harness.reference` (the warm-up's) |
| identity check | `identity`; the `identity` lines |
| AMI, instance, price, AZ | `manifest.json` (run.sh); the `host` line |

Other files under `out/`:
- `events.jsonl`: every streamed line, with field `kind`. The kinds are inputs-tsv, host, tool,
  db, db-huge, input, g1-reference, isal, engine, identity, select, drop-caches, point, defect,
  summary and fatal.
- `points/<id>.tgz`: the point's command, stderr, time records, pipe records and the runner's
  JSON.
- `inputpath.tsv`: the end-of-run table.

`scripts/post/inputpath.sh` (run by `run.sh`) writes `tables/inputpath.tsv` and
`tables/inputpath-defects.tsv` from `out/points.jsonl`.

### Streaming and the deadline (hygiene)

- Every event is one `inputpath {json}` line in the log, which the preamble pushes every 5 s.
- `out/points.jsonl` and the point's CSV and tgz are pushed after every point. A TTL kill
  therefore loses no finished point.
- A point not started by the deadline is still recorded, as `skipped` (`skipped-deadline`). The
  deadline is launch + TTL − `MARGIN_S` (600 s), with launch taken as boot − 120 s.

### Time budget

`scripts/inputpath/estimate.py` is a model, not a measurement. `make inputpath` prints it with
the docstring's cited rates:
- upstream Standard-8 classification at 69 MB/s of FASTQ per thread (G2 loadbench, r8g.2xlarge);
- `gzip -dc` at 200 MB/s (G2 logs);
- rapidgzip at 170 MB/s per thread (probe (c)).

The sample sizes are `inputs.tsv`'s:
- pe SRR062634_8000000: 2 × 2.09 GB FASTQ;
- se SRR4074269: about 5.1 GB FASTQ, estimated from its BGZF at pe's compression ratio.

| session | threads | modelled | TTL | at 1.5× | at 2× |
|---|---|---|---|---|---|
| upstream, c8g / c9g | 48 32 16 | 45 min | 117 / 107 | 60 min | 75 min |
| ours, c8g / c9g | 48 32 16 | 58 min | 117 / 107 | 79 min | 101 min |
| upstream, c8gn | 48 16 | 36 min | 79 | 47 min | 57 min |
| ours, c8gn | 48 16 | 45 min | 79 | 60 min | 74 min |

All six fit, even at 2× the model. A miss is not a lost run: the deadline skips the tail of rep 2
and records it as such.

**The c8gn cut:** c8gn defaults to `THREADS="48 16"` (its TTL is 79 min). `ARGS='THREADS="48 32
16"'` restores the full matrix there (modelled at 45 and 58 min). The chunk-size points at one
threads value are a further cut.

### The rehearsal

`make rehearse SPEC=runs/inputpath-*.json` runs `scripts/lib/inputpath_rehearse.sh`; its header
lists every check. The spec's own body runs on AL2023 aarch64 containers (rootful podman,
`--privileged`) under `bash -e -c`, as ec2-user.

**Real on the node:**
- the bundle clone;
- the upstream build at the pin, and ours' `make build`;
- lever.sh's rapidgzip install;
- pidstat, GNU time and `F_SETPIPE_SZ`;
- tmpfs `huge=always`;
- process substitution into the classifier.

**Stand-ins:**
- S3: the stub aws on a directory.
- The Standard-8 key holds the viral DB.
- The inputs are real public read sets: SRR062634 (its first 1,000,000 pairs) as pe, and ERR478965 mate 1 as
  se. The prep container re-encodes them as BGZF and builds their rapidgzip indexes.
- THP: a fake sysfs file, so the VM's setting is never written.
- The host: 8 CPUs for 64.

**The Law 1 reference** for the rehearsal inputs: upstream at the pin (the shared oracle build)
run on the host on the same inputs and the viral DB, written in #95's `g1_reference` format and
passed as `AK2_REHEARSE_G1_REF`.

**Cases:**
- upstream: A, the full matrix; B, no inputs.tsv; D, drop_caches failing; F, a reference whose
  report sha256s differ (the run must stop after the first warm-up, exit 1).
- ours: C, the full matrix with induced rapidgzip SIGSEGVs: both identity attempts of one
  configuration (excluded), the first attempt of another (a transient: the retry passes and its
  points run), and one timed decode; B; E, a deadline 60 s into the measure phase; F (ours'
  warm-up against a reference that differs).

A and C also run `make inputpath-report`'s script on a mock run dir, which checks the record
contract (`scripts/lib/inputpath_report.py`, from the tree or `origin/inputpath-report`). The
record is `results/rehearse/inputpath-<family>-<engine>-<ts>-<sha>.log`. All six specs share one
body, apart from the parameter lines, and the rehearsal checks that.

### Deviations from the plan (#90), for Scott

- **No instance store.** c8g, c9g and c8gn (no `d`) have none, so I0's "local NVMe" is tmpfs.
  tmpfs is the page cache, so I0 is warm by construction.
- **THP.** "THP always with `--memory-mapping` off puts the table in anonymous memory" does not
  hold at the pin; see "THP" above. The contrast also switches the DB's tmpfs `huge=` setting.
- **No reader thread** to attribute in upstream; see the pidstat bullet above.
- **Ours' I3/I4.** These still decode through rapidgzip pipes. In-process decode from index seek
  points or BGZF blocks is the plan's next step, not yet in ours.
- **Pipe-size contrast.** Added (per-lever attribution): I2 at the best p with the default pipe.
- **ISA-L: none in the pinned Graviton wheel** (#95). The body uses #95's detector
  (`scripts/inputpath/lib.sh`):
  - static: an `isal_inflate_init` symbol or the isa-l attribution in the extension (the
    `isal_inflate` literal is an error string in every build, not evidence);
  - runtime: `rapidgzip -v`'s "Time spent decoding with ISA-L" on the se gz.

  `isal` is true if either finds ISA-L, false if static none and 0 s, else null; the `isal` line
  records both. The rehearsal's real wheel gives false. The ISA-L arm is the second-build switch
  above (`RG2_WHEEL`, the 0.16.0 wheel), off until #97's verdict.
- **I1 for ours** runs twice: through the same `gzip -dc` pipe as upstream (`AK2_DECOMPRESS=pipe`)
  and in process (ours' default).

### Failure looks like

- `inputs: scripts/inputpath/inputs.tsv: …` (fatal line, exit 1): the input list is missing or
  incomplete. Nothing was built or staged.
- `… sha256 … != inputs.tsv …` or `… source_sha256 … is neither …`: a staged object is not the
  one recorded.
- Exit 95: drop_caches failed before the first point.
- `THP enabled=… was not applied`: the sysfs write did not take, so the run ends.
- Status `defect` / a `defect` line: Law 1. This is a finding, so file an issue.
- Status `skipped` with `harness.status_detail` `skipped-identity` or `decode-crash`: a rapidgzip
  crash or mismatch, recorded and never used.

## Records and report

**What:** `make inputpath-report RUN=results/inputpath/<run-id> [OUT=…]` renders the sweep's
report from one run dir and nothing else. Backed by `scripts/lib/inputpath_report.py` (python3,
stdlib only). Test: `make inputpath-report-test` (in `make test`), on the synthetic run dir
`scripts/tests/fixtures/inputpath/synthetic-run/` (Law 3: unit test only, never under
`results/`; `python3 scripts/tests/inputpath_report_test.py --write-fixture` regenerates it).

```bash
make -s inputpath-report RUN=results/inputpath/<run-id> > /tmp/inputpath.md
```

**Inputs** (all inside the run dir):
- `manifest.json`, run.sh's, finalised: `.instance.type/.ami/.az`, `.truffle_price_usd_per_hour`,
  `.billed_seconds`, `.cost_usd`, `.cost_basis`, `.commit`, `.upstream`.
- `out/points.jsonl`: one JSON object per kraken2 run point, written by the harness.
- per point, its `pidstat_csv`, a path relative to the run dir.

**Outputs:** markdown on stdout and in `tables/inputpath-report.md` (or `OUT`), and
`tables/inputpath-summary.tsv` (one row per setting; `make report` renders it). Exit 0 with no
DEFECT, 1 with any DEFECT line (the report is still written), 2 on unreadable input (no run dir,
no or unfinalised manifest, invalid JSON, no points).

### Point record: `out/points.jsonl` (`"schema": "inputpath-point/1"`)

R = required when `status` is `ok`; O = optional, printed as `missing` when absent; n/a = not
applicable to the arm (printed `n/a`).

| field | type | | notes |
|---|---|---|---|
| `schema` | `"inputpath-point/1"` | O | |
| `point_id` | str | R | unique in the file |
| `rep` | int | O | repetition of the same setting, default 1 |
| `arm` | `I0`…`I4` | R | |
| `engine` | `upstream` \| `ours` | R | |
| `family` | str | R | `c8g`, `c9g`, `c8gn` |
| `instance_type` | str | R | must equal the manifest's `.instance.type` |
| `db` | str | O | database name; Law 1 groups by input and db |
| `p` | int | R for I2–I4 | rapidgzip `-P` per mate |
| `threads` | int | R | kraken2 `--threads` |
| `chunk_mib` | int | O | rapidgzip `--chunk-size`, MiB |
| `thp` | `always` \| `never` | R | |
| `pipe_bytes` | int | O | F_SETPIPE_SZ on the decoder's stdout |
| `fanout` | int | O | ours' fan-out width |
| `rapidgzip` | `{version, build: pypi\|source, isal: bool}` | O | I2–I4 |
| `input` | `{role: paired\|single, accession, mates: [{mate, s3_key, sha256}]}` | R (`accession`) | |
| `index_sha256` | str | O | I3 |
| `bgzf_sha256` | str | O | I4 |
| `fastq_bytes` | int | O | decompressed FASTQ bytes over all mates; MB/s = this / 10^6 / wall_s when `fastq_mb_per_s` is absent |
| `wall_s` | number | R | kraken2 wall time of the point |
| `classify_reads_per_s` | number | O | |
| `fastq_mb_per_s` | number | O | MB = 10^6 bytes |
| `classify_window` | `{t0, t1}` | O | in the pidstat CSV's `t_s` time base; absent = whole file |
| `pidstat_csv` | str | O | relative to the run dir |
| `peak_rss_kb` | `{kraken2, rapidgzip, …}` | O | |
| `output_sha256` | str | R | sha256 of `--output` |
| `report_sha256` | str | R | sha256 of `--report` |
| `identity` | `{gz_sha256, rg_sha256, rg_exit, ok}` | R for I2–I4 | rapidgzip vs `gzip -dc` |
| `status` | `ok` \| `skipped` \| `defect` | R | |
| `note` | str | O | |

`skipped` means recorded and never used, such as a rapidgzip crash or identity mismatch. Such a
point is listed and left out of every table and reading. `defect` is the harness's own defect and
is listed as a DEFECT.

**pidstat CSV** (one row per thread per 1 s sample, from `pidstat -t 1`): header
`t_s,tgid,tid,command,role,cpu_pct`, with `role` one of `rapidgzip`, `gzip`, `kraken2_reader`,
`kraken2_worker`, `kraken2_other`, `other`. If `role` is empty on kraken2 threads, the reader is
taken to be the kraken2 thread with the highest mean %CPU in the window, and the report says
"inferred".

### What the report contains

- The run table, from `manifest.json`, with the field cited on each row.
- **One table per family, engine and input:** one row per setting (arm × p × threads × chunk ×
  thp × pipe × fan-out). Repeated points are aggregated as the median and min–max of wall, plus
  FASTQ MB/s, classify reads/s, $/run, peak RSS, and `src` (the `out/points.jsonl` line numbers).
- **$/run:** the truffle price at launch × the setting's median `wall_s` / 3600. This is the
  point's wall-second share of the session at the launch price, compute only. The session's DB
  load, setup and idle time are not spread over the points; the report prints the used walls'
  share of the billed seconds. If `cost_usd` differs from price × billed by more than 1%, the
  report says so.
- **CPU attribution per arm at its best setting** (lowest median wall). It reads the pidstat CSV of
  the point whose wall is nearest the median, over its `classify_window`. Per role it gives the
  thread count, cores (the sum of the threads' mean %CPU / 100), share, and an ASCII bar. Each
  CSV is cited with its sha256.
- **Pins:** the rapidgzip version/build/ISA-L, the I3 index sha256 and the I4 BGZF sha256, each
  with its lines.
- **Law 1:** within each (input, db), every used point's `output_sha256` and `report_sha256` must
  equal those of the reference I0 point (upstream's I0 if present, else ours'). Each difference
  is a `DEFECT (Law 1)` line, and the point is left out of the tables. Other DEFECT kinds:
  - `(identity)`: an `ok` I2–I4 point whose identity check failed (rg_exit ≠ 0, the shas differ,
    or ok not true);
  - `(record)`: a required field is missing, an enum value is bad, a duplicate `point_id`, or
    `instance_type` ≠ the manifest's;
  - `(harness)`: `status: defect`;
  - `(Law 1 unverifiable)`: no usable I0 point for that input.

  Any DEFECT gives exit 1.
- **Readings**, per family, engine and input, then one summary line each.

### Reading rules

The thresholds are constants at the top of the script. Every comparison uses the median wall of
a setting.

- **Noise and resolution.** When both settings have n ≥ 2, the noise is the larger of their two
  min–max ranges, divided by the reference's median. If the noise is over 5%, the probe cannot
  resolve a 5% effect, so that comparison is *unresolved* and the reading is *undecided*
  (Law 4).
- **R1: I1 within 5% of I0** means single-stream gzip is struck from H-knee. Each I1 setting is
  compared with the best I0 at the same threads and thp. The reading *applies* if I1 ≤ I0 × 1.05
  at every matched setting. It *does not apply* if any matched setting exceeds that. It is
  *undecided* if there is no matched pair or a pair is unresolved.
- **R2: I2 or I3 reaches I0 at some p.** The reference is I0's best setting (lowest median wall
  over threads and thp). For each (p, arm), the best I2/I3 setting (over chunk and pipe) at the
  reference's threads and thp is compared with it. "Reaches" means
  (X − I0) / I0 ≤ the tolerance:
  - 5% if either side has a single point;
  - with n ≥ 2 on both sides, the noise, but at least 1%.

  The reading *applies* at the smallest p that reaches, which is the recommended setting. It is
  *undecided* if a smaller p is unresolved, or if nothing reaches and something is unresolved.
  The same line gives the plan's pipe cost: I2 at its best p vs I0, and whether that is under 10%.
- **R3: I0 limited by one saturated reader thread while the workers idle**, meaning upstream's
  serial parse and batch is the ceiling. The test uses I0's best setting, from its pidstat CSV
  over the classify window. The reading *applies* if the kraken2 reader thread's mean is ≥ 90%
  of one CPU and the kraken2 workers' mean is < 50%. It is *undecided* if there is no CSV or no
  reader or worker threads.
- **R4: I4 vs I2, the BGZF lever value.** The best I4 setting is compared with the best I2 at the
  same p, threads and thp. The value is reported as (I2 − I4) / I2, *within 5%* (no measurable
  value) or *beyond 5%*. It is *measured*, or *undecided* if no I4, no matching I2, or
  unresolved.
