# The ladder lever library (`scripts/g3/lever.sh`)

**What:** the deployment levers that the #25 ladder rungs switch, one shell function per lever,
shared by both arms (stock and ours). A rung's body sources the library and calls each lever
with the rung's choice as an argument. Lever choices travel in the payload, never in env.
Every call records what it did and counts its S3 requests. The ladder body, generator and
lever table (#51) are built on it. This is a stub runbook: the library and its test only.

```bash
make lever-test        # AL2023 in podman, under the preamble; record in results/rehearse/
```

## Use from a body

```bash
cd "$W/repo" && . scripts/g3/lever.sh || exit 1   # after the preamble and the clone
lv_nvme raid /mnt/nvme
ak2_phase fetch-db
lv_stage_db awscp-default s3://<bucket>/<prefix>/ "$LV_NVME/db"
lv_etag "$LV_NVME/db/hash.k2d" "$(lv_db_etag "$LV_NVME/db" hash.k2d)"   # its own phase
ak2_phase fetch-inputs
lv_fetch_inputs lanes16 default "$LV_NVME/in" "$W/inputs.txt"   # S0's client, 16 lanes
lv_gunzip_shim rapidgzip-P16
lv_upload_start s5cmd-overlap
#   ... per sample: classify, then lv_upload_enqueue OUT s3://<results bucket>/<key>
#   (OUT must not change until lv_upload_drain)
lv_upload_drain
```

The contract (signatures, modes, records, request-count basis and rehearsal seams) is the
header of `scripts/g3/lever.sh`. Changing it means changing #51 too.

| function | modes | stock (S0) | rung |
|---|---|---|---|
| `lv_nvme MODE MOUNT` | `single`, `raid` | | |
| `lv_stage_db MODE SRC_URL DEST_DIR [FILE...]` | `awscp-default`, `awscp-classic`, `s5cmd` | `awscp-default` | S1: `s5cmd` |
| `lv_etag FILE EXPECTED` | (its own phase) | | |
| `lv_fetch_inputs MODE CLIENT DEST MANIFEST` | `serial`, `lanes<K>`; client `default`, `classic`, `crt` | `serial default` | S6: `lanes16 default` (the lanes only) |
| `lv_upload_start MODE` / `_enqueue LOCAL S3URL` / `_drain` | `awscp-default`, `awscp-classic` (alias `awscp-serial`), `awscp-overlap`, `s5cmd-serial`, `s5cmd-overlap` | `awscp-default` | S7a: `s5cmd-serial`; S7b: `s5cmd-overlap` |
| `lv_gunzip_shim MODE` | `gzip`, `rapidgzip-P<k>` | `gzip` | S5: `rapidgzip-P<k>` |
| `lv_s5 ARGS...` | the only way s5cmd is called | | |

**S7 is two rungs (Law 5: one lever per rung).** The upload mode is a tool and a schedule:

| | serial (enqueue uploads, returns when done) | overlap (one background lane) |
|---|---|---|
| aws CLI | `awscp-default` (S0), `awscp-classic` | `awscp-overlap` (default client) |
| s5cmd | `s5cmd-serial` (S7a: the tool) | `s5cmd-overlap` (S7b: the overlap) |

S7a changes only the tool (awscp-default → s5cmd-serial) and S7b only the schedule
(s5cmd-serial → s5cmd-overlap). `awscp-overlap` is the other order (schedule first), if #51
wants to check that the two levers compose.

## What it guarantees

- **Failures are surfaced.** Every failure returns non-zero and also goes through `ak2_err`,
  so the run's exit status carries it even if the body ignores the return code.
  - An upload that fails in the overlap lane is a lane failure. `lv_upload_drain` waits for the
    lane by PID and fails if the lane failed or any upload failed or is missing.
  - The lane checks at the top of every iteration that the body's shell is alive, so it cannot
    outlive a killed run. If drain cannot write the lane's END marker, it kills the lane and
    fails at once instead of leaving it to poll until the TTL.
- **Records.** Every call appends a JSON line to `$LV_DIR/lever.jsonl`, echoed into the run
  log as `lever {json}` (streamed by the preamble's pusher) and pushed to `out/lever.jsonl`.
  Uploads are rows of `out/lever-uploads.tsv`. A staged database's ETags and sizes are in
  `out/lever-db-<dir>-SOURCE`.
- **Law 1 across arms.** s5cmd's part size changes an object's S3 ETag, so the sha256 of every
  upload is computed on the node and recorded at enqueue, before the upload starts. The file
  must not change between enqueue and drain.
- **Bucket allow-list.** `lv_s5` refuses (rc 126):
  - any `s3://BUCKET` outside `AK2_ALLOWED_BUCKETS`, in any argument;
  - any argument equal to `run` (the run subcommand reads commands it cannot check);
  - `--endpoint-url` or `-endpoint-url` in any spelling, and a set `S3_ENDPOINT_URL`
    (another endpoint is another S3).

  Flags are parsed in both `--long` and `-long` spellings. `lv_s5` is read-only to the body.
  The preamble's aws shim already covers the aws CLI.
- **Pins, checked against hashes in lever.sh** (a checksum file from the same release would
  only catch corruption):
  - s5cmd 2.3.0: the release tarball's sha256 (`LV_S5_SHA256_arm64`, `LV_S5_SHA256_64bit`;
    checked on 2026-10-09 by hashing the downloaded tarballs, and equal to the release's
    checksum file). The tarball and binary sha256 are recorded.
  - rapidgzip 0.14.5: `pip download` then `pip install`, both `--require-hashes` against the
    sha256 of its manylinux wheels on PyPI (`LV_RG_HASHES`: aarch64 and x86_64, CPython 3.9,
    which is AL2023's python3, to 3.13). The wheel's and the extension's sha256 are recorded.
  - Both versions are checked after install.
- **Stock is the AMI's aws CLI as shipped.** The `default` client (`awscp-default`) runs `aws s3
  cp` with no config override; an `AWS_CONFIG_FILE` the body exported is removed for the call
  (`env -u`). `classic` and `crt` force that transfer client in a private `AWS_CONFIG_FILE`,
  passed to the one command and never exported. `classic` is available but not used by S0.
  `crt` also sets `multipart_chunksize = 8MB`.
  - The first use of each client records a line of kind `aws-client`: the CLI version, the
    config and its content (`none` for default), `aws configure get
    default.s3.preferred_transfer_client` (empty when nothing is configured; v2 then uses
    `auto`), the instance type, and `resolved` with `how`. For `default` it also records the
    AMI's own config: `~/.aws/config` and any file under `/etc/aws` (presence and content), and
    `~/.aws/credentials` (presence only).
  - `resolved` is the configured client if one is named, or `classic` for CLI v1. For v2 on
    `auto` it is the CLI's own rule, read from its source
    (`awscli/customizations/s3/factory.py`): CRT if `awscrt.s3.is_optimized_for_system()` and
    no other aws CLI process holds the CRT process lock
    (`_is_crt_client_running_in_other_aws_cli_process`), else classic. lever.sh checks that the
    source has this rule, evaluates the first part with the CLI's own python (the CLI must be a
    python script, as AL2023's rpm is: `#! /usr/bin/python3 -s`), and records the lock as a
    caveat in `how`. Otherwise `resolved` is `unknown`, with the reason.
  - It records `awscrt.s3.get_optimized_platforms()` (awscrt 0.36.4 in AL2023's rpm:
    trn1n.32xlarge, trn1.32xlarge, p6-b300.48xlarge, p6-b200.48xlarge, p5en.48xlarge,
    p5e.48xlarge, p5.48xlarge, p4de.24xlarge, p4d.24xlarge) and whether the host and the ladder
    types (r8gd.48xlarge, x8g.24xlarge) are on it. Neither ladder type is, so `default`
    resolves to classic on every ladder host.
- **Requests** are derived from sizes, as the rest of the repo counts them. For the aws CLI the
  basis is the classic client's algorithm: 8 MiB threshold and parts. It is exact only where
  classic ran. When a client resolves to `crt` or `unknown`, every op of its transfers is
  written as `<op>-estimate` in `requests.tsv` (for example `GetObject-estimate`), and the
  lever record has `estimate: true`, so they cannot be read as measurements. The head-objects
  lever.sh makes itself are always plain. For s5cmd the basis is its `--part-size`.

## The test (`make lever-test`)

`scripts/tests/lever_test.sh` builds `localhost/ak2-lever-test`: AL2023 with gzip, tar, perl,
diffutils and the `awscli-2` rpm, plus the rapidgzip 0.14.5 wheel (`/opt/wheels`) and the s5cmd
2.3.0 release tarball (`/opt/s5`) downloaded at build time. The tag is the Containerfile's
hash. It then runs `scripts/preamble.sh` followed by `scripts/tests/lever_body.sh` as
`bash -e -c`, the way spawn starts a body.

**Stand-ins**, only at the edges:
- curl answers IMDS and the bucket-region HEAD;
- aws and s5cmd are stubs over a shared directory. They log every call with its start and end
  times. Uploads under `up/` take 2 s and input gets take 0.4 s, so overlap and lane
  concurrency show in the timestamps;
- sudo runs the command;
- `AK2_REHEARSE_NVME` and `AK2_REHEARSE_S5CMD` (the stub) are set. `AK2_REHEARSE_WHEELS`
  points pip at the image's wheel dir, so rapidgzip goes through the real `--require-hashes`
  install. The s5cmd tarball pin is checked with `AK2_REHEARSE_S5CMD_TGZ` on the real tarball.

**Cases:**
- **main** must exit 0 with no helper errors. It checks:
  - `awscp-default` reaches the CLI with no config, even with a body-exported crt config, and
    records the AMI's `~/.aws/config`. `awscp-classic` runs under the classic config. s5cmd
    gets its flags. Each client is recorded;
  - the auto rule, evaluated against the image's real AL2023 `awscli-2` rpm, resolves to
    `classic` in a container. Its `how` names the CRT process lock, its platform list includes
    p4d.24xlarge, and both ladder types are off it;
  - estimates: the stub CLI resolves to `unknown`, so its transfers count as
    `GetObject-estimate` and similar, and `crt` fetches likewise. lever.sh's own head-objects
    stay plain;
  - fetch: the `default` client for serial and lanes, `crt` under its config with
    `multipart_chunksize = 8MB`;
  - the anonymous fallback;
  - the staged files are identical, and the request counts;
  - a real multipart ETag in its own phase;
  - serial and `lanes3` fetches both verify, with serial never overlapping and lanes
    overlapping;
  - the shim is byte-identical to `gzip -dc` on plain and multi-member gz, both directly and
    through perl's `open "gzip -dc FILE |"` as upstream's wrapper calls it. rapidgzip really
    ran, and was installed from a wheel whose sha256 is a pin. The record carries the paired
    concurrency (2 shims, 2k threads);
  - uploads:
    - serial blocks, for both `awscp-default`/`awscp-classic` and `s5cmd-serial` (the
      contrast that shows the probe resolves the effect);
    - `awscp-overlap` and `s5cmd-overlap` enqueue return at once, and upload 1 runs inside the
      body's next work;
    - uploads run in enqueue order, and drain waits;
  - each sha256 is recorded before its upload and equals the object's;
  - `lv_s5` finds the subcommand with single-dash flags;
  - the real s5cmd tarball installs against its pinned sha256.
- **refuse** checks nine refusals (undeclared buckets in any position, `run` as a subcommand
  and as any argument, `--endpoint-url`, `-endpoint-url=`, `S3_ENDPOINT_URL`), s5cmd never
  reached, and exit 126.
- **fail** checks each of these returns non-zero, and the run exits 1 with each in
  `helper-errors.tsv`:
  - a wrong ETag, a bad sha256 and a failed lane upload;
  - bad modes and a bad client;
  - a drain that cannot write END, which kills the lane at once;
  - a tampered s5cmd tarball and a tampered rapidgzip wheel, both refused by their pins.

The driver also checks that `lever.sh` passes `errexit_check.py` (run.sh does not check
sourced files) and that `lever {json}` lines streamed. `CASES="refuse"` runs one case, for
debugging; `KEEP=1` keeps the work dir.

**Not covered locally:**
- `lv_nvme` on real devices (mdadm, mkfs.xfs and mount). The test covers only its rehearsal
  seam.
- The downloads from GitHub and PyPI themselves (the image fetched the same files at build
  time).
- Real S3 request counts.
- The lane's main-shell check (the body's shell is the test itself).

These are first exercised by the ladder rehearsal and the first ladder run (#53).

# The ladder body, lever table and generator (#51)

**What:** one spec body for both arms of both #25 ladders (S → S\*: upstream at the pin; S\* →
O\*: ours), the table of every rung, and the generator that turns a rung into a spec.

```bash
make ladder-check                                   # one key-group per rung, counterparts, endpoints
make ladder-spec ARM=S RUNG=S1 COHORT=1             # runs/g3-l-s1-c1.json
make ladder-spec ARM=S RUNG=S1 COHORT=10 TTL=240    # other cohorts give TTL (minutes)
make dryrun-userdata                                # DRY_RUN=1 of every committed spec, recorded
make run GATE=g3 SPEC=runs/g3-l-s1-c1.json NODES=1  # NODES = WANT_N (REPLICAS x SHARDS)
make ladder-stream-test                             # the body's launch and watch functions (in make test)
```

## The lever table (`scripts/g3/ladder.levers.tsv`)

One row per rung; its header comment defines the columns. Read by `scripts/lib/ladder_levers.py`,
the generator, and by column name by #52's `ladder_tables.py`. `lever` is what the tables report:
the key-group, except `stock` (S0-T1), `threads` (S0-Tv), `host-tunes` (S3) and `rapidgzip` (S5). `group` is the
key-group the one-lever check compares.

**Key-groups:** CLASSIFIER; THREADS+PROCS; DB_STAGE; DB_PLACE+DB_LOAD; HOST_TUNES; GUNZIP;
IN_FETCH+IN_CLIENT+IN_DEST; OUT_UPLOAD; REPLICAS+SHARDS; PLACEMENT; INFLIGHT; SETUP; ETAG_CHECK;
HOST (the instance type). REPLICAS and SHARDS are one group, the fleet layout, so O1 (K replicas
→ one K-shard engine at equal $/h) is one lever. THREADS and PROCS are one group, P × T.

**The check** (`make ladder-check`, also in `make test`; `--self-test` shows each failure mode is
caught): against its predecessor, a rung's changed keys, less the keys its `coupled` column names
with a reason, fall in exactly its `group`. A coupled key must really change and lie outside the
group. Every counterpart is an existing rung or `none: <reason>`. ETAG_CHECK is `on` everywhere.
Each of S\*-time, S\*-cost, O\*-time and O\*-cost is declared for cohorts 1, 10, 100 and 1000 on
exactly one rung (`endpoint`, `c<cohort>:<endpoint>;...`). The module is importable (`load`,
`check`, `resolve`, `changed`, `coupled_keys`, `spec_params`) for #53's `ladder_check.py`.

**Rungs that are not one lever, and why** (the `coupled` column):
- **S2a** (host r8gd.48xlarge → x8g.24xlarge) also moves the inputs to tmpfs (IN_DEST): x8g has no
  instance store, and Scott ruled that the inputs move at S2a. A separate IN_DEST rung on
  r8gd.48xlarge before S2a would remove the coupling.
- **O0b** (ours' plain path → the engine at N = 1) also changes DB_STAGE/DB_PLACE/DB_LOAD to
  ranged-get/memory/resident and PROCS/INFLIGHT to 1/P. It cannot be split: the engine has no -M,
  so it holds the table resident, and a resident copy beside the staged tmpfs copy is
  2 × 1107 GiB, over the 1536 GiB of every S\* host. PROCS → INFLIGHT is the same sample width
  carried into one process.

**Splits made for Law 5:** S2b → S2b-i (`-M` on the same NVMe) then S2b-ii (the table on tmpfs);
S7 → S7a (tool) then S7b (overlap); O4 → O4a (LPT) then O4b (in flight).

**Endpoints** are rungs declared before any run: `Sstar-time` and `Sstar-cost` are S9 on the host
whose rung (S9, Sstar-r8g, Sstar-r8gd) has the lowest median wall_s (billed_usd) at that cohort;
ladder 2 starts from `Sstar-time`; O5, its top, is O\*-time and O\*-cost.

**Not-run rungs** (`status`: `run`, or `not-run: <reason>`): kept for the record, never
generated, never a predecessor, and they must change nothing against their own predecessor.
S3 is one: the tune probe (run 20261009-223514-4ee77c3) selected `none` for both regimes, and the
null is not evidence of no effect (regime a's load, median 243.4 s, sits at the 244.4 s network
floor; regime b's spread was 33 s). So HOST_TUNES is `none` throughout, S3's lever is
`host-tunes`, and S4's predecessor is S2a. O0b's tune (regime b) is also `none`.

**Placeholders:** `@probe-tune` (a host-tune set still to be chosen; none is left) and `@select:<rung>[:<KEY>]`
(S4's P × T, S8's K, the S\* hosts, O2's family, O3's N, O4b's in flight; `@select:S4:PROCS`
means S4's PROCS value). Descendants carry the same token, so one resolution reaches every rung
that inherits it. `scripts/g3/ladder.resolved.tsv` (absent so far: columns origin, cohort, key,
value, source) resolves a token per cohort, and every row must name the `results/` file it comes
from. The generator refuses any rung with a placeholder left.

**Predictions:** `pred_*` are filled only where a measured rate gives one: S5's `pred_phase_s`
(−7.8 s at c1, from probe (c), if classify is gzip-bound). Classic `aws s3 cp` has never been
measured, so S1 has none. Modelled values go in `results/g3/ladder-modelled.tsv` (header only
until c10 is measured; the c100 S0-T1 row is modelled from c10's per-thread rate).

## The generator (`scripts/g3/mkspec-ladder.sh ARM RUNG COHORT [TTL=<min>]`)

It writes `runs/g3-l-<rung>-c<cohort>.json`: the body with its `@PARAMS@` line replaced by
`RUNG=…; ARM=…; COHORT=…; WANT_N=…; <every PARAM>` (in the payload, never in env),
`env.AK2_ACCESSIONS = @PRJNA398089:1-<C>`, the type and AZ pinned (so the driver is run-multi.sh
with NODES = WANT_N), 60 GiB disk, and `cost_limit` = TTL × the truffle on-demand price + $0.005,
to the cent. It refuses: a table that fails the check; ARM other than the rung's; any placeholder;
a type whose memory (or one NVMe device) cannot hold the rung at that cohort (the table on tmpfs
or in the process, inputs and outputs at 150 B per pair, 16 GiB of slack; the engine by
mkspec.sh's rule); a cohort other than 1 without TTL. The same table, cohort and price give the
same bytes. `run.sh` and `run-multi.sh` write the PARAMS block into `manifest.params` and
`cohort.json` `params` (`ladder_levers.py spec-params`: lowercase keys, ints for cohort, want_n,
replicas and shards, `run_kind: ladder`, `state: cold`); other specs get `params: null`.

Generated and committed at c1 (every rung fully determined there): S0-T1, S0-Tv, S1, S2b-i,
S2b-ii, S2a. All six pass `DRY_RUN=1` (user data, cost and quota checks):
`results/rehearse/dryrun-userdata-*-<sha7>.tsv`.

## The body (`scripts/g3/ladder.body.sh`)

Its header lists the phases; they are the same on both arms: setup, fetch-db, etag-hash.k2d,
fetch-inputs, identity (S5 and later only), load, classify, upload-drain, push. The engine's order
is fetch-inputs, load, etag-hash.k2d, classify: its ETag is checked on the table it loaded.
- **Cold by construction.** `ak2_drop_caches` before anything, and again before `load`.
  `lad-mem` records Cached, Dirty, Writeback and the huge-page counters at load start.
- **Build.** Upstream from source at the pin (`scripts/oracle-build.sh`), ours at the run's commit
  (`make build`). SETUP=serial waits for the build in setup; overlap waits just before load.
- **ETag on every arm.** Upstream and ours-plain: `lv_etag` on the staged hash.k2d. The engine:
  `AK2_ENGINE_VERIFY_ETAG=1`, and the run fails without its `ak2-engine etag` line.
- **Phase boundaries** come from the classifiers' own output. load → classify on the first
  "Loading database information... done."; for the engine, load → etag-hash.k2d on its
  `shard-load` timing line and → classify on its `connect` line. A boundary never observed is
  still opened when the classifiers end, so every run has every phase.
- **Per-sample path** (upstream, ours-plain): PROCS lanes, samples placed by PLACEMENT. Under a
  serial upload mode (awscp-default, s5cmd-serial) a lane's next sample waits until the main shell
  has uploaded the previous one; under overlap it does not. Ours-plain gets `AK2_DECOMPRESS=pipe`
  whenever a shim is in use. **Engine path:** one cohort-mode process per node over the replica's
  samples (`parallel:<PLACEMENT>`, INFLIGHT in flight); a serial upload mode is refused, because it
  could not hold back the engine's next sample.
- **Fleet:** rank r is replica r / SHARDS, shard r % SHARDS; replicas split the cohort by
  PLACEMENT, and each engine replica has its own rendezvous (`…/rendezvous/g<replica>`).
- **lad-sample** (#52's contract v1): one line per classified sample, streamed into the run log
  and appended to `out/lad-samples.jsonl`. Fields: v, arm, rung, cohort, accession, pairs, rc,
  phases (seconds to the ms: classify, sha, upload when serial, s5-identity, classify-process,
  engine-*), t_start and t_end (the sample's work interval, epoch seconds to the ms), outputs (output
  and report: bytes and the sha256 that `lv_upload_enqueue` computed on
  the node before the upload), s5 {status n/a|identical|differs, fallback none|gzip, gz_sha256 and
  rg_sha256 (per mate, in mate order, when status is not n/a; identical means they are equal), P, nproc},
  plus rank, idx, t_start, t_end, input_bytes and threads. No classified/unclassified outputs are
  written. Under O5's `sdk-stream` there is no local copy: the line waits for the push phase,
  where each output is fetched by GET and hashed (`sha256_source` says so).
- **S5.** The shim goes on PATH only (lever.sh), and the run fails if `$KRAKEN2_DIR` holds a gzip
  or bzip2. The identity phase compares rapidgzip -P k with gzip -dc, by sha256, on every input at
  this run's -P, and records -P and nproc. A sample that differs gets `s5.status: differs`
  ("S5 not output-preserving on this input") and falls back to GNU gzip by per-sample shim
  behaviour: a `gzip` ahead of the shim on PATH sends exactly its inputs to GNU gzip, and logs
  them (`out/s5-fallback.calls`). After classify the run fails unless `gzip-shim.calls` has at
  least 2 rapidgzip lines per non-fallback sample, and the fallback log 2 per fallback sample.
  `rapidgzip-Pauto` is k = clamp(floor(nproc / (2 × samples at once)), 1, 16), resolved on the node.
- **Streaming order.** `cmd 2> >(tee FILE | sed …) > /dev/null`: the process substitution forks
  with the stdout in effect at that point, the run log. `make ladder-stream-test` checks this on
  observed output, and shows the reverse order streams nothing.

**Rehearsal seams** (`AK2_REHEARSE_*`, which run.sh refuses in a spec's env): lever.sh's (NVME,
S5CMD, S5CMD_TGZ, RAPIDGZIP, WHEELS), upstream-cohort.sh's RAMDB_ROOT, and the body's GO,
HT_ROOT, HASH_URL, SAMPLES and WEIGHTS, as probe_rehearse.sh and cohort_rehearse.sh use them.
The full local rehearsal (Standard-8 served as RODA, K = 2 replicas, N = 2 shards, end-to-end
Law 1) is #53.

**Not covered locally:** the body end to end (#53); real NVMe, tmpfs and drop_caches; the
identity phase on real rapidgzip (lever-test covers the shim).
