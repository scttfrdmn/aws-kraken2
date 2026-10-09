# The G3 cohort: make stage-cohort, cohort mode, the upstream arm, E1 (#25)

**What:** the real cohort the G3 sweep uses (Law 3), how it is recorded and staged, and how the
engine and upstream run it. Scott's decisions are on #25: calibrate with E1 first; upstream at
cohort 1000 is modelled from real upstream runs at 1, 10 and 100 and flagged as extrapolation.

## The cohort: make stage-cohort

```bash
make stage-cohort PART=record            # once, before any use: results/cohort/PRJNA398089/
make stage-cohort COUNT=10               # stage the first 10 (from the launch host: slow, see below)
make run GATE=g3 SPEC=runs/stage-cohort.json NODES=8   # ranks 11..1000 on 8 instances, one slice each
make tag-objects PREFIX=s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/cohort/        # afterwards, from the launch host
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
    afterwards with `make tag-objects PREFIX=s3://aws-kraken2-942542972736-us-west-2/aws-kraken2/data/cohort/`.
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

    batch  inflight  mode  s3client  name  [weight=<n>]  argument…

- **mode `parallel`** (sample-parallel): each sample has one home node, which reads, classifies
  and writes it alone, its lookups routed to every shard. Placement (`cmd/aws-kraken2/place.go`):
  - `parallel` or `parallel:mod`: sample j of the batch is homed on node j mod N, and a node runs
    its samples in manifest order. This was E1's design and is now the control.
  - `parallel:lpt`: samples are taken heaviest first by `weight=<n>` (pairs or bytes, one unit
    per batch; required on every sample), each going to the node with the least weight so far.
    Ties go to manifest order, then to the lowest rank. A node runs its samples heaviest first.
    Every node computes the same placement from the manifest.
  - `make oracle-cohort`'s `n3-lpt` mode checks byte-identity under LPT, and checks every
    observed home rank against the placement recomputed from the manifest
    (`scripts/lib/lpt_check.py`). It requires the LPT placement to differ from j mod N there.
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
- **Per-sample record:** one `ak2-sample` line per sample on stderr, with these fields:
  - batch, name, mode, client, rank, role, inflight, threads;
  - start, wall, setup, classify, close and report seconds;
  - exit status, sequences, bases, classified;
  - place and weight.
- **Memory samples:** with `AK2_TIMINGS=1`, an `ak2-engine mem` line every `AK2_MEM_EVERY`
  seconds (default 15). It gives VmRSS, VmHWM, the Go heap and MemAvailable.
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

## The G3 campaign (#25; Scott approved it 2026-10-08)

```bash
make g3-spec EXP=e2 TYPE=x8g.4xlarge N=8 COHORT=100 [ARGS="INFLIGHT=4 TTL=60"]   # runs/g3-e2-x8g.4xlarge-n8.json
make rehearse SPEC=runs/g3-e2-x8g.4xlarge-n8.json N=3     # must pass; commit its results/rehearse/ log
make run GATE=g3 SPEC=runs/g3-e2-x8g.4xlarge-n8.json NODES=8
make g3-tables                                            # results/g3/campaign/{points,spend,rules}.tsv, summary.md
```

- **Spec generation.** `scripts/g3/mkspec.sh` writes the spec from `scripts/g3/campaign.body.sh`,
  with the parameters as a block at its head. It also symlinks the cohort post
  (`scripts/post/<spec>.cohort.sh` points to `g3-campaign.cohort.sh`).
  - It refuses a type whose memory cannot hold the shard plus 15%, plus 8 GB, plus 7.5 GB per
    sample in flight. Before this rule, E3's 96 GiB c8g.12xlarge at 6 in flight was OOM-killed.
  - Disk is sized for the inputs a node reads. The per-member cost_limit is the truffle price
    times the TTL.
- **The body.** It runs one cohort-mode invocation `c<COHORT>` over the first COHORT runs of the
  recorded cohort. The batches are:
  - 0: LPT;
  - 1: the j mod N control;
  - 2: LPT again, for the within-run spread;
  - then sample 1 block-striped, C1_REPS times;
  - then sample 1 on its home node, C1_REPS times.
  Each node fetches only the inputs it reads, through `scripts/g3/fetch.sh`. That runs as a child
  process with lanes waited for by PID, under a watchdog. The body's earlier `wait -n` loops
  failed at 8a6dbe6 and hung at 1a4dbfe on AWS. Defaults are the SDK emitter, T16, and in flight
  = vCPUs / 8.
- **The tables.** `scripts/post/g3-campaign.cohort.sh` writes them under `tables/`, from the record
  only:
  - `tidy`, `rates`;
  - `batches`, with imbalance and planned imbalance;
  - `samples`;
  - `consistency`, from `outputs.tsv`;
  - `point`, the phases, the batch walls by role, and the derived cohort time and $/sample;
  - `placement-check.txt`;
  - `provenance.tsv`.
  `scripts/lib/g3_campaign.py` gathers every point and every run's spend since the campaign
  began. It evaluates the stopping rules of #25 into `rules.tsv`.
- **T, defined** (`point.tsv`, `points.tsv`):
  - **derived_T:** the sum, over the terms below, of each term's maximum over the ranks. It is
    not any one rank's path. The terms are boot (launch to body start), setup, manifest, fetch,
    load, and the LPT batch's wall.
  - **observed_T:** the first launch to the last rank's end of batch 0, the measured critical
    path. **skew_rendezvous** = observed_T − derived_T: ranks reaching the rendezvous at
    different times, the rendezvous itself, and the batch's start skew. The gap grows with N, to
    19–25 s at N = 16.
  - **Tails:**
    - the body tail runs from the engine process's end (its `total` timing) to the body's end:
      request accounting and the stderr push;
    - the harness tail runs from the body's end to EC2's terminated, so it is the harness, not
      the engine. Its maximum, median and top 3 over ranks are listed, because one slow node sets
      the maximum.
  - **T_engine** = observed_T + body tail. **T_with_harness** = T_engine + the maximum harness
    tail.
  - **The rules are evaluated both ways.** The x8g knee is read next to `fleet_vcpus`: E2's fleets
    are memory-equal, not vCPU-equal (96, 96, 128, 128, 128).
  - **$/sample:**
    - `derived_usd_per_sample_*` = N × price × T / cohort;
    - `measured_usd_per_sample_whole_run` = the summed member cost / cohort, which covers every
      batch of the run.
  - **The placement + order lever** (j mod N against LPT, which also orders each node's samples
    heaviest first) is resolved only if its gain exceeds 2 × the within-run spread.
- **`make g3-frontier`** (`scripts/lib/g3_frontier.py`) writes the H-main per-axis bests and the
  Pareto sets: `results/g3/campaign/frontier.{tsv,md}` and `pareto.tsv`.
  - They are given per cohort size (1, 10, 100) and regime (resident, from-scratch), ours against
    upstream at its best (U1, U2, with fq preparation added back).
  - Upstream at its best is the better of single-node upstream and upstream sample-parallel (N
    independent nodes, each holding the table; #25 ruling 1). The sample-parallel arm is derived
    from the single-node measurements (per-node fixed costs plus measured per-sample walls, LPT
    over N × P slots; per-node staging paid N times from scratch); the whole N sweep is
    `upstream_sp_sweep.tsv`. The kill condition is evaluated per regime (#25 ruling 2).
  - $/sample is derived (price × nodes × wall) on both sides.
  - Each ratio is decomposed by Law 5: time into width × per-vCPU efficiency; $/sample into price
    per vCPU-hour × per-vCPU efficiency; staging alongside, from scratch.
  - The registered references and the kill condition are evaluated mechanically.
  - Ours at cohort 1000 is a placeholder only; upstream's model there is infeasible as
    specified.
  - frontier.md's definitions are generated from the script's docstring.
- **`make g3-fit`** (`scripts/lib/fit26.py`, #26; WP-10 of the #25 ladder, which O3 uses to
  choose N) fits the registered model and writes `results/g3/fit26/`. See "make g3-fit" below.
- **Defect attempts** are named in `scripts/lib/g3_defects.tsv` and carried into `spend.tsv` and
  `summary.md`, in three classes:
  - `defect`, our own;
  - `capacity`, us-west-2a InsufficientInstanceCapacity;
  - `partial`, a run completed by a later one.
- **Pre-fix engine (#44):** the outputs of E1–E4 and checkpoint 2 come from an engine that walked
  ResolveTree's hits in first-hit order. The fix, the clean-room `HitCounts`, is 904c2a5.
  - `engine_pre_fix` marks every engine point affected, in `point.tsv`, `points.tsv`,
    `u2-pairs.tsv` and `law1-u2.tsv`; the E1 summary records it too.
  - By inference, only reads hitting an orphan taxonomy node can differ.
  - The cohort samples whose U1 cross-check changes are in
    `results/g3/campaign/prefix-engine.tsv`.
- **`make bash-jobs-test`** runs `scripts/tests/bash_jobs.sh` under AL2023's bash, in podman.
  - It rebuilds the body's environment: `bash -c`, the preamble's traps, a FIFO tee and push
    loop, and process substitutions.
  - The body's old fetch loops must fail there. On its first run, bare `wait -n` hung, and
    `wait -n -p` looped on "no such job".
  - The current `scripts/g3/fetch.sh` and U1's in-shell lanes, waited for by PID, must pass.
  - The record goes to `results/rehearse/bash-jobs-*.txt`.
- **`make rehearse` asserts memory feasibility** for a campaign spec: its type must hold 1/N of
  hash.k2d plus 15%, 8 GB, and 7.5 GB per sample in flight. The per-sample figure is measured:
  `scripts/lib/g3_memory.py` writes `results/g3/campaign/memory.tsv` from the `ak2-engine mem`
  lines. The earlier 2 GB let E3 c8g.12xlarge at 3 in flight through, and it was OOM-killed.
  Every rank must also stream
  `ak2-engine mem` lines.
- **`make g3-law1-u2`** downloads the engine's sample-1 output and report from the E2 N=8 cohort
  and makes two checks:
  - `ak2etag.py` must equal their real S3 ETags, multipart and single-part;
  - their sha256 must equal U2's upstream sha256 for every SRR5935740 rung.
  It writes `results/g3/campaign/law1-u2.tsv`.
- **`scripts/lib/abort_uploads.sh KEYPREFIX RECORD`** records and aborts open multipart uploads
  from the launch host.
- **U1** (`runs/g3-u1-x8g.24xlarge.json`, `scripts/g3/u1.body.sh`) is upstream resident on
  tmpfs with `-M`:
  - cohorts 1, 10 and 100, with gz and fq;
  - T in {48, 96, 192};
  - P x T for gz at cohort scale, as LPT lanes: 12 x 8, 24 x 4, and 48 x 2, which is an
    addition to the registered U1 (Scott, 2026-10-08) to bracket the optimum;
  - fq is pre-decompressed onto tmpfs before each sample's rungs. Each preparation is timed (a
    `u1-prep` line; `prep.tsv`), and the fq rungs are labelled pre-decompressed;
  - upstream at cohort 100 gz, one process at a time, is modelled from the best measured
    one-process gz rate. It is flagged MODELLED in `rungs.tsv`;
  - drift references with buddyinfo and the compaction counters.
  Its cohort-100 fq T=96 rung computes the engine writer's S3 ETag of every upstream output
  (`scripts/lib/ak2etag.py`). `scripts/lib/u1_tables.py` compares those ETags with the `outputs.tsv` of every E2, E3 and E4
  cohort that produced a point. That is Law 1 on the real cohort, without downloading the
  outputs. It fails on any difference, on a sample or file missing from any cohort, and on zero
  comparisons (`law1-coverage.tsv`).
- **U2** (`runs/g3-u2-r8gd.16xlarge.json`, `scripts/g3/u2.body.sh`, `scripts/g2/u2.plan`) is the
  #40 NVMe ladder, plus the cohort's sample 1, through make g2's runner.
- **Rehearsals:**
  - `make rehearse` dispatches by spec: `e1_rehearse.sh` for E1, `cohort_rehearse.sh` for E2–E6,
    `u_rehearse.sh` for U1, `u2_rehearse.sh` for U2.
  - The campaign rehearsal checks, on observed output:
    - streaming: the streamed sample lines equal the manifest's lines;
    - placement: lpt_check, and that LPT differs from j mod N when N > 1;
    - requests: the objects under out/ equal both the manifest's outputs and the request counts;
    - Law 1: every output is identical to upstream's.

## make g3-fit: the #26 fit (registered T(N) and cost, then each addition)

```bash
make g3-fit      # results/g3/fit26/: fit26.md, manifest.json and the tables listed below
make test        # includes scripts/lib/fit26_test.py (the fitting code on synthetic data with known parameters)
```

- **Inputs.** The script reads the record only, and launches nothing:
  - `results/g3/campaign/points.tsv`;
  - each point's cohort `tables/{point,batches,rates}.tsv` and `cohort.json`;
  - E1's `tables/batches.tsv` and `tables/summary.md` (r_input);
  - `results/g3/campaign/frontier.md` (the #44 hitbench ratio, quoted only);
  - `results/cohort/PRJNA398089/runs.tsv`;
  - `results/instance-types/us-west-2.json`;
  - hash.k2d's HEAD (`results/g0a/20261006-005556-fe849b2/out/head-hash.k2d.json`);
  - `results/util-backfill/util-backfill.tsv`.

  It does not rerun `make g3-tables`. Every file it reads is listed in `manifest.json` with its
  sha256, beside the commit and the script's own sha256. Regenerate the campaign tables first if
  they are stale.
- **Observable.** T = `T_with_harness_s`, from the first launch to the last member's
  termination, end to end (#25 ruling, 2026-10-09). Its phases (boot + setup + manifest, fetch,
  load, LPT wall, skew, body tail, harness tail max) sum to it; the script asserts this to
  within the 1 s rounding.
- **Fits** (`params.tsv`; the fit column names each one):
  - `R`: the registered form, exactly as registered, fitted end to end on T. Only
    K = t_boot + t_probe + t_gather + t_tail is identifiable.
  - `R+<addition>`: one fit per addition, each refitted from scratch on the same points:
    - t_input (E1's r_input);
    - t_emit (samples per lane);
    - t_net (routed lookup bytes at the NIC's peak rate);
    - t_fetch (input GB/N; not identifiable at a single cohort size);
    - t_sync (log2 N);
    - c_used (threads in use instead of vCPUs);
    - B_nic (B proportional to the NIC).
  - `P-reg`: the registered terms, each fitted to its own phase, so t_boot and t_tail separate.
  - `P-full`: every addition, per term. Its classify term is also fitted on the cohort-1 walls,
    which identifies r_input.
- **Checks** (`residuals.tsv`, `heldout.tsv`):
  - residuals per point;
  - leave-one-out refits for every point;
  - the designated held-out point, E4 c8g.12xlarge N=32, fitted on the other 8. Its z uses the
    prediction interval, se = sqrt(se_param² + s²), with s from the refit (sqrt(rss/dof) end to
    end, the T rmse for the per-term fits);
  - a cohort-size check of the classify term against every point's cohort-1 wall and E1's
    cohort-10 batches (E1 placed j mod N, so its rank imbalance is shown).
  - An added parameter counts as resolved only if |value| / se >= 2. Negative values of
    parameters that must be non-negative are flagged as unphysical.
  - s uses the true rank of J. In a singular fit (R+t_fetch), parameters in J's null space get no
    value; the others are printed without an se.
  - The per-term fits' covariance is block-diagonal (each term fitted on its own phase), so their
    standard errors and optimal-N ranges are understated.
- **The registered cost** (`cost_residuals.tsv`, `hwidth_knee.tsv`):
  - per point, the registered cost formula with P-reg's t_boot, t_tail, B and r, against the
    derived $ (N × p × T) and the billed $ (all batches, so not like for like). Fit R cannot
    check it: with only K identifiable, its formula equals N × p × T exactly.
  - H-width's cost knee, N* = (S/B + W/(c·r)) / (t_boot + t_tail), from P-reg, per type and
    cohort, beside the memory floor.
- **Predictions** (`predictions.tsv`, `optimal.tsv`):
  - N ranges over 1..64, for every measured type at its truffle price, and the cohort over 1,
    10, 100 and 1000.
  - Memory feasibility follows `mkspec.sh`'s rule. In flight is vCPUs / 8, reduced to what
    memory holds.
  - Cost = N × p × T. The registered cost formula is shown beside it for P-reg. For R the
    column reads "= N*p*T (only K is identifiable)".
  - Per family, the time-optimal and cost-optimal type and N are reported, with the 16–84% range
    of the optimal N over 200 parametric draws.
  - A cell is **extrapolated** if any of its fit's regressors lies outside the range the fit's
    observations span, if its cohort is not 100, or if its optimum sits at the grid edge.
  - It is also flagged **joint** when every regressor is in range but the combination is not:
    the prediction's leverage x'(X'X)⁻¹x exceeds the largest leverage of the fit's own
    observations. A type measured only at another N is listed beside it.
  - Every table carries an `engine_pre_fix` column.
- **Pre-fix.** Every point is marked `engine_pre_fix` (the #44 fix, 904c2a5), and `fit26.md`
  says so. Regenerate the points with the fixed engine and rerun `make g3-fit` before quoting a
  parameter as post-fix.

## Rehearsal: make rehearse SPEC=runs/g3-e1.json [N=3]

Run before every launch of a cohort spec. Every `make rehearse` first runs `make util-stream-test`
with the same N ([util.md](util.md)), and fails if it fails. That test checks, on N AL2023
containers running the real stub and preamble, that `log/util.tsv` streams on every node. The
stand-ins below replace the preamble, so the rehearsal proper cannot check it.
`scripts/lib/e1_rehearse.sh` runs the spec's own body
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
