# The G3 cohort: make stage-cohort, cohort mode, the upstream arm, E1 (#25)

**What:** the real cohort the G3 sweep uses (Law 3), how it is recorded and staged, and how the
engine and upstream run it. Scott's decisions are on #25: calibrate with E1 first; upstream at
cohort 1000 is modelled from real upstream runs at 1, 10 and 100 and flagged as extrapolation.

## The cohort: make stage-cohort

```bash
make stage-cohort PART=record            # once, before any use: results/cohort/PRJNA398089/
make stage-cohort COUNT=10               # stage the first 10 (from the launch host: slow, see below)
make run GATE=g3 SPEC=runs/stage-cohort.json NODES=8   # ranks 11..1000 on 8 instances, one slice each
make tag-objects PREFIX=aws-kraken2/data/cohort/        # afterwards, from the launch host
```

- **PRJNA398089** is IBDMDB/HMP2 stool metagenomes, from ENA.
- **Recording.** `record` queries ENA's filereport and keeps paired WGS runs that have exactly
  `<run>_1.fastq.gz` and `<run>_2.fastq.gz` with md5s. It orders them by run accession
  (numerically) and writes the first 1000 to `results/cohort/PRJNA398089/runs.tsv` (rank, run,
  sample, read count, base count, and per mate: URL, bytes, md5). `query.json` holds the query
  URL, time, rule, the sha256 of the raw response and of the TSV, and the commit.
  - Recorded 2026-10-07 at 9c28466: 2041 runs qualify. The 1000 have 11.06G pairs and 1.10 TB of
    fastq.gz; the first 10 have 110.2M pairs and 10.65 GB.
  - A recorded cohort is never re-recorded. Cohorts {1, 10, 100, 1000} are prefixes of it.
- **Staging.** `stage` downloads the first COUNT runs from ENA and checks bytes and md5 against
  `runs.tsv`. It uploads them to `s3://<results bucket>/aws-kraken2/data/cohort/` with sha256
  and md5 metadata, checks those with head-object, tags the objects, and appends to
  `results/cohort/PRJNA398089/staged.tsv` (run, mate, bytes, md5, sha256, key, VersionId). It is
  idempotent.
  - On an instance (`runs/stage-cohort.json`), the role is the credential and cannot tag. Tag
    afterwards with `make tag-objects PREFIX=aws-kraken2/data/cohort/`.
  - **Slices.** STAGE_FROM, STAGE_STRIDE and STAGE_OFFSET select the ranks r in STAGE_FROM..COUNT
    with (r − STAGE_FROM) mod STRIDE = OFFSET. The spec stages ranks 11..1000 and, with
    `NODES=n`, gives member k the slice STRIDE = n, OFFSET = k. The spec's body records the
    requests from its log: RANGES ranged GETs to ENA per fetched file; per upload, one PutObject,
    or CreateMultipartUpload + ceil(bytes / 8 MiB) UploadPart + Complete; and the HeadObjects.
  - The cohort post (`scripts/post/stage-cohort.cohort.sh`, `scripts/lib/stage_merge.py`) merges
    every member's `out/staged.tsv` into `results/cohort/PRJNA398089/staged.tsv`, in cohort order
    and one row per object version. It checks that every rank 11..1000 has both mates with
    runs.tsv's bytes and md5 (`tables/staged-check.tsv`), and exits 1 otherwise.
  - From an instance in us-west-2, one ENA stream is about 1 MB/s (2026-10-08), so `stage`
    fetches STAGE_PARALLEL files at once (default 4) in STAGE_RANGES ranged streams (default 8).
    An object already staged is not fetched again but is recorded from its metadata.
  - From the launch host, ENA runs at about 50 KB/s per stream (about 260 KB/s with 8 ranged
    streams), measured 2026-10-07. Staging there is impractical.
- Staging beyond the first 10 waits for Scott (storage is about $18 a month for 1000).

## Cohort mode: AK2_COHORT

`AK2_COHORT=<manifest> aws-kraken2 [common arguments]`, with `AK2_ENGINE_N` (and for a
multi-node run, `AK2_ENGINE_RANK`, `AK2_ENGINE_RENDEZVOUS` and so on; [engine.md](engine.md)).
The table, or this node's shard, is loaded **once** for every sample. The manifest is
tab-separated, one sample per line:

    batch  inflight  mode  s3client  name  argument…

- **mode `parallel`** (the default design): sample j of a batch has home node j mod N, which
  reads, classifies and writes it alone, its lookups routed to every shard.
- **mode `striped`:** every node takes every N-th block of the sample and rank 0 emits it, as a
  single multi-node invocation does. One control session per sample; the shards stay loaded.
- **inflight:** samples a node runs at once. **s3client:** `sdk` (aws-sdk-go-v2), `cli` (an aws
  process per part), or `-` (`AK2_S3_CLIENT`, default sdk).
- **Batches** run in order, with a rendezvous barrier between them in a multi-node run. A failed
  sample anywhere ends the cohort at the end of its batch (exit 1).
- **Arguments:** each sample's own kraken2 arguments, appended to the common ones. Each sample is
  parsed and run exactly as a separate invocation with those arguments, so its outputs are
  upstream's (`make oracle-cohort`). Every sample names its `--output`. Outputs, the report
  included, may be `s3://` objects.
- **Check-only mode:** `AK2_COHORT_CHECK=1` parses the manifest and every sample's arguments,
  then exits without loading anything. E1 checks its manifests this way before the first shard
  load.
- **Per-sample record:** one `ak2-sample` line per sample on stderr: batch, name, mode, client,
  rank, role, inflight, threads, start, wall, setup, classify, close and report seconds, exit
  status, sequences, bases, classified.
- **The SDK path** goes around the aws PATH shim, so the engine enforces the bucket allow-list
  itself. `AK2_ALLOWED_BUCKETS` (set by `make run`) must name the bucket, or the SDK store refuses
  it. `AK2_S3_INFLIGHT` sets parts in flight (default 8 SDK, 4 CLI). `AK2_S3_ENDPOINT` is for
  tests only (a fake S3, `k2probe fakes3`).

## The upstream arm: scripts/upstream-cohort.sh

`run KRAKEN2 MANIFEST OUT.jsonl [common arguments]` runs every sample of the same manifest
through upstream, one invocation each, and records exit, wall, classify seconds and the sha256 of
every output. `ramdb SRC NAME SIZE` puts the database on a huge=always tmpfs at the fixed path
`/mnt/ak2-ramdb/NAME` (G2's ram regime; it refuses an existing mount point, and the mount is the
invoking user's, mode 0700; `umount NAME` removes it), so
with `--db <tmpfs> --memory-mapping` in the common arguments no sample reloads the table:
upstream at its best for a cohort (Law 2).

## Rehearsal: make rehearse SPEC=runs/g3-e1.json [N=3]

Run before every launch of a cohort spec. `scripts/lib/e1_rehearse.sh` runs the spec's own body
(its `command[2]`, unmodified) locally as N nodes, under the environment the harness gives a
cohort member. Three E1 spec bugs were found only on AWS; this finds that kind of bug for free.
- **Harness and instance stand-ins:**
  - the `ak2_*` helpers, and the cohort env (`AK2_COHORT_ID`, `AK2_ENGINE_N`/`RANK`/`RENDEZVOUS`,
    `AK2_COHORT_PREFIX`, `AK2_ALLOWED_BUCKETS`);
  - sudo/dnf; `git clone`, which becomes a `git archive` of the commit in the cohort id, so the
    committed tree is what runs;
  - the Go download; IMDS (127.0.0.1); and GNU tools.
- **Data stand-ins:**
  - Standard-8's `hash.k2d` served as RODA's by `k2probe serve-file` (ranged GETs with If-Match),
    with no local `hash.k2d` on any node;
  - S3 as one directory, through `k2probe fakes3` (the SDK path) and a stub `aws`
    (`scripts/lib/rehearse_aws.py`, the CLI path and the body's s3api calls). The stub models the
    instance role: it refuses list-object-versions and abort-multipart-upload with AccessDenied;
  - 3 real local read sets as the cohort's samples.
- **What runs:** setup, fetch, manifest building, `AK2_COHORT_CHECK`, every invocation, and rank
  0's consistency check, end to end.
- **What passes:**
  - every rank exits 0;
  - every rank's body output (its run log on AWS) has streamed `[c10] ak2-sample` lines;
  - every output of every variant of every sample is byte-identical to upstream kraken2 at the
    pin on that sample.
- **Seams:** the body reads `AK2_REHEARSE_N`, `AK2_REHEARSE_HASH_URL` and `AK2_REHEARSE_SAMPLES`.
  run.sh refuses them in a spec's env and never sets them, so on AWS they are always unset.
- **Record:** `results/rehearse/<spec>-<UTC>-<commit>.log`. `REHEARSE_KEEP=1` keeps the work
  directory.
- **Requires:** Standard-8 locally and the upstream oracle build. It takes about 7 minutes.

## E1: runs/g3-e1.json (calibration; launch only on CLEAR-TO-LAUNCH)

`make run GATE=g3 SPEC=runs/g3-e1.json NODES=8`: the full plan (Scott chose option b,
2026-10-08), on 8 × x8g.4xlarge in us-west-2a with RODA v205 and the first 10 cohort samples. The
invocations and batches are in the spec's header.
- **Law 1.** E1 has no upstream arm and does not check Law 1. Law 1 for these code paths rests on
  the local oracles (`make oracle-cohort`, `make oracle-engine`: per sample, against upstream) and
  on checkpoint 2's RODA identity on AWS. E1 checks consistency only: every variant of a sample
  (CLI or SDK, in flight 1 or 2, 16 or 8 threads, parallel or striped, reload or not) must have
  one ETag per output. Rank 0 checks it on the node (`out/consistency.tsv`, from ListObjectsV2).
  The cohort post recomputes it on the launch host as `tables/consistency.tsv`, from
  `outputs.tsv` (run-multi's list-object-versions, `Versions[?IsLatest]`), and also asserts the
  variant counts: 8 for the c1 sample, 5 for the others. The E1 run at cb0cea7 has only the
  launch-host table: its on-node listing was denied (no s3:ListBucketVersions). That table, and
  the batches, samples, invocations and summary tables, were computed after the run;
  `tables/provenance.tsv` records the commit.
- **Streaming.** Every engine line (`ak2-sample`, `ak2-timing`, `ak2-engine`) goes into the run log
  as it is written (pushed every 5 s), so a TTL kill loses at most the last lines. Each rank's
  stderr is also pushed after each invocation. The `2> >(…)` process substitution must come before
  `> /dev/null`, because it forks with the stdout in effect at that point. E1's runs up to and
  including cb0cea7 had the other order and streamed nothing. Only the per-invocation stderr
  pushes kept their data. `make rehearse` now checks for the streamed lines.
- **Requests.** `ak2_req` per invocation: the shard load's ranged GETs (`ak2-engine load`), and
  every S3 request of the process by operation and client (`ak2-engine s3`; rendezvous included,
  with `ak2-engine rendezvous` giving its puts and gets).
- **Tables.** The post scripts write `tables/tidy.tsv` per member. For the cohort,
  `scripts/post/g3-e1.cohort.sh` writes these under `results/g3/<cohort>/tables/`:
  - `tidy.tsv` and `rates.tsv`: the measured rates against the sweep estimate's basis;
  - `consistency.tsv`;
  - `batches.tsv`, `samples.tsv` and `invocations.tsv`;
  - `provenance.tsv`;
  - `summary.md`, generated by `scripts/lib/e1_summary.py`.
  Rerun the script on a cohort dir to regenerate them.
- **Cost, from the measured RODA basis** (results/g3/20261007-202107-5faa28c-1b65-n8: load 81.5 s
  at 1.82 GB/s; about 425k pairs/s cluster-wide on a block-striped sample, bound by the CLI
  emitter):
  - Full: 582.6M pairs (3 × 10.53M + 5 × 110.2M).
  - Rank imbalance: the 10 samples fall on 8 nodes, so in a sample-parallel batch rank 1 has
    35.4M pairs against a mean of 13.8M.
  - **Pessimistic** (sample-parallel no faster per node than the emitter-bound striped run, about
    53k pairs/s per node): about 31–60 min, $6.5–12.5.
  - **Expected** (per node bound by single-stream gunzip, about 1.25M pairs/s, or CPU, about
    1.7M pairs/s; CLI emit about 450k pairs/s): about 14–20 min, $2.9–4.2.
  - The SDK emit rate, unmeasured so far, decides where E1 lands.
  - The TTL is 120 min, twice the pessimistic bound. cost_limit is $3.30 per member, above the
    TTL's own cost (2 h × $1.5632), so the cost limit cannot end the run first. The cohort's
    ceiling is $26.40, under the $50 backstop.
