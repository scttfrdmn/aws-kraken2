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
