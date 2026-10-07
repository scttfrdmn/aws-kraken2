# The G3 cohort: make stage-cohort, cohort mode, the upstream arm, E1 (#25)

**What:** the real cohort the G3 sweep uses (Law 3), how it is recorded and staged, and how the
engine and upstream run it. Scott's decisions are on #25: calibrate with E1 first; upstream at
cohort 1000 is modelled from real upstream runs at 1, 10 and 100 and flagged as extrapolation.

## The cohort: make stage-cohort

```bash
make stage-cohort PART=record            # once, before any use: results/cohort/PRJNA398089/
make stage-cohort COUNT=10               # stage the first 10 (from the launch host: slow, see below)
make run GATE=g3 SPEC=runs/stage-cohort.json   # the same, on an instance (ENA is fast from AWS)
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
    afterwards with `make tag-objects PREFIX=aws-kraken2/data/cohort/`, and commit the run's
    `out/staged.tsv` as `results/cohort/PRJNA398089/staged.tsv`.
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
every output. `ramdb SRC DST SIZE` puts the database on a huge=always tmpfs (G2's ram regime), so
with `--db <tmpfs> --memory-mapping` in the common arguments no sample reloads the table:
upstream at its best for a cohort (Law 2).

## E1: runs/g3-e1.json (calibration; launch only on CLEAR-TO-LAUNCH)

`make run GATE=g3 SPEC=runs/g3-e1.json NODES=8`: 8 × x8g.4xlarge in us-west-2a, RODA v205, the
first 10 cohort samples. The invocations and batches are in the spec's header.
- **Ranks.** Every rank pushes its stderr per invocation. Rank 0 writes `out/consistency.tsv`:
  every variant of a sample (CLI or SDK, in flight 1 or 2, 16 or 8 threads, parallel or
  striped, reload or not) must have one ETag per output.
- **Tables.** The post scripts write `tables/tidy.tsv` per member and, for the cohort,
  `results/g3/<cohort>/tables/{tidy,rates}.tsv`. `rates.tsv` holds the measured rates the
  sweep's estimate assumed: load GB/s, worker CPU per pair, lookups and routed bytes per pair,
  read (gunzip) seconds, emit and close seconds.
- **Expected cost:** about $3–4 (8 × $1.56/h × about 16 min); cost_limit $1.40 per member.
