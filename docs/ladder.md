# The ladder lever library (`scripts/g3/lever.sh`)

**What:** the deployment levers that the #25 ladder rungs switch, one shell function per lever,
shared by both arms (stock and ours). A rung's body sources the library and calls each lever
with the rung's choice as an argument. Lever choices travel in the payload, never in env.
Every call records what it did and counts its S3 requests. The ladder body, generator and
lever table (#51) are built on it. This runbook covers the library and its test, then the ladder tables (`make g3-ladder`, #52) and their input contract.

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

**The one rung that is not one lever, and why** (the `coupled` column; O0b-cost is its copy):
- **O0b** (ours' plain path → the engine at N = 1) also changes DB_STAGE/DB_PLACE/DB_LOAD to
  ranged-get/memory/resident and PROCS/INFLIGHT to 1/P. It cannot be split: the engine has no -M,
  so it holds the table resident, and a resident copy beside the staged tmpfs copy is
  2 × 1107 GiB, over the 1536 GiB of every S\* host. PROCS → INFLIGHT is the same sample width
  carried into one process.

**Splits made for Law 5:**
- S2b → S2b-i (`-M` on the same NVMe), then S2b-ii (the table on a tmpfs with huge=never, the tmpfs
  default), then S2d (that tmpfs mounted huge=always; `DB_PLACE=tmpfs-huge`). The inputs' tmpfs is
  huge=never on every rung.
- S2c (the inputs onto tmpfs, on r8gd.48xlarge; lever `IN_DEST`) before S2a, so S2a changes the host
  only (Scott, 2026-10-10).
- S7 → S7a (tool) then S7b (overlap); O4 → O4a (LPT) then O4b (in flight).

**Endpoints** are declared before any run, on `Sstar-time`, `Sstar-cost`, O5 and O5-cost.
`Sstar-time` and `Sstar-cost` are **aliases** (`status: alias: …`, candidates in `alias_of`): they
have no runs of their own. Each is the runs of the candidate (S9, Sstar-r8g, Sstar-r8gd) that its
registered rule selects at that cohort, so nothing is run twice. The selection is a row of
`ladder.resolved.tsv` (origin `Sstar-time`, the cohort, key `alias`, the winning rung, its source),
and the alias's host, which O0's `=pred` inherits, is the winner's. The tables must read an alias
rung as its winner's runs (`scripts/tests/ladder_levers_tables_test.py` stands in for that until
they do). S\*-cost and O\*-cost are chosen by the **lowest median billed $** (Scott, 2026-10-10);
effective cost per resource is still reported for every endpoint.
**Ladder 2 runs twice** (Scott, 2026-10-10): the time side O0 … O5 from `Sstar-time`, with O3's N
the fit's time-optimal one, and the cost side O0-cost … O5-cost from `Sstar-cost`, with its own
selections (`@select:O2-cost`, `@select:O3-cost` at the cost-optimal N, `@select:O4b-cost`). O5 is
O\*-time and O5-cost is O\*-cost, so each pair's lever rows follow its endpoint's own predecessor
chain back to S0-T1. The S rungs' counterparts name both sides.

**Not-run rungs** (`status`: `run`, `not-run: <reason>`, or `alias: <rule>` for the S* endpoints): kept for the record, never
generated, never a predecessor, and they must change nothing against their own predecessor.
S3 is one: the tune probe (run 20261009-223514-4ee77c3) selected `none` for both regimes, and the
null is not evidence of no effect (regime a's load, median 243.4 s, sits at the 244.4 s network
floor; regime b's spread was 33 s). So HOST_TUNES is `none` throughout, S3's lever is
`host-tunes`, and S4's predecessor is S2a. O0b's tune (regime b) is also `none`.

**Placeholders:** `@probe-tune` (a host-tune set still to be chosen; none is left) and `@select:<rung>[:<KEY>]`
(S4's P × T, S8's K, the S\* hosts, O2's family, O3's N, O4b's in flight; `@select:S4:PROCS`
means S4's PROCS value). Descendants carry the same token, so one resolution reaches every rung
that inherits it. `scripts/g3/ladder.resolved.tsv` (absent so far: columns origin, cohort, key,
value, source) resolves a token per cohort. The generator refuses any rung with a placeholder
left, and refuses a resolution when:
- its source is not an existing `results/…` path inside a run or cohort dir (a directory below
  `results/` holding `manifest.json` or `cohort.json`);
- it resolves S4 with neither THREADS nor PROCS as a `vcpus/<k>` ratio;
- after resolving, the one-lever check, run again on the resolved values against the resolved
  predecessor, fails: the rung is identical to its predecessor (mark it not-run instead), or it
  changes another key-group. THREADS, PROCS and INFLIGHT are compared as numbers, each resolved
  with `vc()` at its own rung's host (vCPUs from the type's size), so `THREADS=96, PROCS=vcpus/96`
  on x8g.24xlarge is S2a's `THREADS=vcpus, PROCS=1` and is refused. The same text on two hosts is
  a derived move with the host's own lever (the `derived` column), not a second lever;
- an alias's winner is not one of its `alias_of` candidates.

**Not run at some cohorts** (`not_run_cohorts`, `c<cohort>: <reason>;...`): a rung whose selection
has a single candidate at a cohort, its predecessor's own configuration, is not run there. Its
tokens then resolve to that predecessor's values, so its descendants stay determined. S4 and S8 are
not run at c1: P and K are at most the cohort, so P = 1 with T = vcpus (S2a's) and K = 1 (S7b's). At
c1 S5's run predecessor is therefore S2a, and S9's is S7b. The tables must skip a rung at the
cohorts it lists, as they skip `status: not-run`.

**Selection rules** (the `select` column, registered before any run; every `@select:<rung>`
selection has one, and a rule names the candidates, the axis and the ties):

| rung | candidates | axis | ties |
|---|---|---|---|
| S4 | P × T = vCPUs, P a divisor of vCPUs, P ≤ cohort; recorded as THREADS=T, PROCS=vcpus/T | median wall_s | fewer processes |
| S8 | K = 1 … min(cohort, the free X quota in x8g.24xlarge) replicas | median wall_s | fewer nodes |
| Sstar-time | S9, Sstar-r8g, Sstar-r8gd (alias) | median wall_s | fewer vCPUs |
| Sstar-cost | S9, Sstar-r8g, Sstar-r8gd (alias) | median billed_usd | fewer vCPUs |
| O2 / O2-cost | the c8g, c9g, r8g and x8g types whose memory holds 1/N of the table at O1's N | wall_s / billed_usd | fewer fleet vCPUs |
| O3 / O3-cost | N ∈ {1, 2, 4, 8, 16, 32, 64} that O2's type can hold | the #26 fit's time-optimal / cost-optimal N | fewer nodes |
| O4b / O4b-cost | INFLIGHT 1 … vCPUs / THREADS on O3's type, memory permitting | wall_s / billed_usd | fewer in flight |

Ladder 1 is one chain until S\*, so S4 and S8 select on time. On one host, billed $ is price × wall,
so S4's two axes give the same order; S8's do not, and its cost side is left to the S\*-cost
endpoint and to the cost-side ladder 2.

**Derived parameters** (the `derived` column names what moves with each lever):
- `THREADS=vcpus`, and any `vcpus/<k>`, is resolved on the node from its nproc, with a minimum of 1.
- `rapidgzip-Pauto` follows the host's vCPUs and the samples at once.
- So a rung that changes the host (S2a, Sstar-r8g, Sstar-r8gd, O2, O2-cost) moves them too. That
  is why S4's P × T is carried as a ratio of vCPUs (PROCS=vcpus/T), not as absolute counts.
- Every `lad-config` line records each PARAM as given (`params`) and the values used (`resolved`:
  threads, procs, inflight, gunzip_P, nproc).

**Measurement-only phases** (Scott, 2026-10-10: every delta and pair is reported gross and net of
them, with the net figure as the headline; the ETag check stays in, because it is a real user step
on every arm):

| name | scope | what | on the critical path |
|---|---|---|---|
| `identity` | run phase (`run:identity`) | S5's rapidgzip vs gzip check on every input | strictly sequential: after `build-wait`, before `load`; nothing else runs beside it, so all of it |
| `sha-get` | run phase (`run:sha-get`, O5 and O5-cost only) | the GET and sha256 of each output the SDK emitter streamed | strictly sequential, after `upload-drain`: all of it |
| `sha` | sample phase (`phases.sha`) | the sha256 of a sample's outputs at enqueue (gross) | informational only; see `sha-critical` |
| `sha-critical` | sample phase (`phases["sha-critical"]`) | the part of the sample's hash intervals that no classify span on the node covers | as defined |

`build-wait` (SETUP=overlap only) is **not** measurement-only. It is the wait for the build that
ran beside fetch-db and fetch-inputs, and the `lad-build` line records `build_end`. It comes before
`identity`, so the build never overlaps identity and identity's saving is exactly its duration.

**sha-critical, by interval overlap.** A sample's hash intervals are `[t − sha256_seconds, t]`
for each of its outputs, from lever.sh's upload-enqueue records. Its critical part is the seconds
of those intervals that no classify span on the node covers:
- per-sample path: each sample's span is `[start, end]`, a running sample covering up to the hash;
- engine: the engine's classify phase, up to its exit.

So a hash done after the last classify ended is all critical, and the last sample's hash always
is. A hash done while another sample classifies is not. With one lane under a serial upload mode,
the lane is idle while it hashes, so each hash is critical.

**The net rule.** Each node writes one `lad-net` line, streamed and the only line of
`out/lad-net.jsonl`:

    {"v": 1, "rank": <int>, "critical_measurement_s": <s, 3 decimals>,
     "identity_s": <s>, "sha_get_s": <s>, "sha_critical_s": <s>}

Here `critical_measurement_s` = identity_s + sha_get_s + sha_critical_s, and sha_critical_s is the
sum of the node's samples' `sha-critical`. A node with nothing to subtract writes 0.

    net wall = max over nodes (node end − critical_measurement_s of that node) − first launch

The node end is its `instance.terminated_at`. Gross wall is the same expression without the
subtraction.

**Bounds:**
- Exact for one lane, the engine, and O5.
- An **upper bound** on the true net wall under a serial upload mode with several lanes. There, a
  hash covered by another lane's classify span still holds up its own lane, so less is
  subtracted than the hashes cost.

`phases.s5-identity` is each sample's share of `identity` and is already inside `identity_s`.

The input sha256 against its metadata (NB10) is **not** separated. It runs inside lever.sh's
`lv_fetch_inputs` (scripts/g3/fetch.sh), in the fetch lanes and overlapped with the other files'
GETs, so separating it would mean changing the #50 contract. It is the same on both arms and stays
inside `fetch-inputs`.

**Run order** (Law 4, cheapest rung first):
- Within each cohort, run the rungs cheapest first, by TTL × price from the generator, or by the
  measured cost once a rung has run.
- Cohorts go c1, then c10, then c100.
- n = 2, with rep 2 in the reverse order of rep 1.

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
same bytes. Each spec's body opens with a comment giving its TTL and cost_limit as runaway backstops sized by
estimate, and noting that the classic `aws s3 cp` rate is unmeasured. `run.sh` and `run-multi.sh` write the PARAMS block into `manifest.params` and
`cohort.json` `params` (`ladder_levers.py spec-params`: lowercase keys, ints for cohort, want_n,
replicas and shards, `run_kind: ladder`, `state: cold`); other specs get `params: null`.

Generated and committed at c1 (every rung fully determined there, 15): S0-T1, S0-Tv, S1, S2b-i,
S2b-ii, S2d, S2c, S2a, S5, S6, S7a, S7b, S9, Sstar-r8g, Sstar-r8gd. All of them pass `DRY_RUN=1` (user data, cost and quota checks):
`results/rehearse/dryrun-userdata-*-<sha7>.tsv`.

## The body (`scripts/g3/ladder.body.sh`)

Its header lists the phases; they are the same on both arms: setup, fetch-db, etag-hash.k2d,
fetch-inputs, build-wait (SETUP=overlap only), identity (S5 and later only), load, classify,
upload-drain, sha-get (O5 and O5-cost only), push. The engine's order
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
  written. Under O5's `sdk-stream` there is no local copy: each output is fetched by GET and hashed
  in the `sha-get` phase, and each sample's line streams (and is pushed) as soon as its GETs finish
  (`sha256_source` says so).
- **Engine checks.** A shard reads exactly the samples the placement homes on it. A failure of
  `cohort_place.py needs` or `table`, or any disagreement between the two (an empty NEED while
  samples are homed there, say), is fatal. After classify, every home sample must have its
  ak2-sample line, or the run fails.
- **S5.** The shim goes on PATH only (lever.sh), and the run fails if `$KRAKEN2_DIR` holds a gzip
  or bzip2. The identity phase compares rapidgzip -P k with gzip -dc, by sha256, on every input at
  this run's -P, and records -P, nproc and each tool's real exit status. Each status is taken inside
  the tool's own command substitution, because the pipeline's PIPESTATUS is gone once the
  substitution returns. A mate differs if:
  - the two sha256 differ;
  - either tool exits non-zero;
  - or either output is empty (the empty-stream sha256, e3b0c442…).

  The lad-sample `s5` carries `gz_exit` and `rg_exit` (per mate) beside the sha lists. A sample that differs gets `s5.status: differs`
  ("S5 not output-preserving on this input") and falls back to GNU gzip by per-sample shim
  behaviour: a `gzip` ahead of the shim on PATH sends exactly its inputs to GNU gzip, and logs
  them (`out/s5-fallback.calls`). After classify the run fails unless `gzip-shim.calls` has at
  least 2 rapidgzip lines per non-fallback sample, and the fallback log 2 per fallback sample.
  **Registered rule** (accepted, 2026-10-10): `rapidgzip-Pauto` is k = clamp(floor(nproc /
  (2 × samples at once)), 1, 16) threads per mate, where samples at once is PROCS (per-sample path)
  or INFLIGHT (engine). It is resolved on the node, recorded in `lad-config` (`gunzip_mode`) and in
  every lad-sample `s5.P`, and the identity phase runs at that same -P.
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
## Ladder tables: `make g3-ladder` (#52)

`scripts/lib/ladder_tables.py` builds the ladder's attribution tables from the record only and
writes them to `results/g3/ladder/`. It launches nothing and costs $0. It writes every table
first, then exits 1 if there is any DEFECT.

`make test` runs `scripts/lib/ladder_tables_test.py` on a synthetic record whose every expected
value is worked by hand. It covers:
- an unresolvable delta, and a delta below instrument granularity;
- sha and file-set mismatches, which exit 1;
- incomplete and failed runs (scenario A), excluded with a DEFECT and kept out of the medians;
- a Law 1 DEFECT, which excludes its run;
- an accession that appears only on the O arm, which has no upstream reference and is a DEFECT;
- a cohort member that never launched (DEFECT incomplete), and a cohort whose planned set comes
  from cohort.json rather than from its members;
- the S5 cases:
  - gzip fallback, kept and reported as a finding;
  - `differs` without a fallback, a contract DEFECT;
  - S entries that disagree on `rg_sha256`, flagged;
  - O-arm `differs` entries matched, or not, to an S entry by `rg_sha256`;
- a rung marked `not-run`, whose successor's delta is taken against the nearest run ancestor;
- a cold endpoint run on an undeclared rung, which gets a note;
- a missing util row and a node-only util row, both reported as missing;
- the fleet cost_usd used as the effective-cost numerator;
- a 2-node cohort run;
- per-cohort and duplicate endpoint declarations;
- an endpoint-run total with a non-zero residual;
- per-lever decompositions that sum to their totals;
- modelled rows:
  - derived by `ladder_model.py` (c10 → c100, worked by hand), and ignored with a note where
    measured runs exist;
  - refused when hand-entered (the reviewer's case: 99999 citing a real file and sha256), when
    stale (a new c10 run since), or when a cited file does not exist;
  - the model itself is refused when a run's span exceeds its wall (F < 0), and a c10 run with a
    Law 1 DEFECT cannot feed it;
- missing terminated_at, a bad PARAMS enum and a bad `v`.

```bash
make g3-ladder-model  # results/g3/ladder-modelled.tsv: c100 stock T1 from the c10 S0-T1 records (exit 2 if none)
make g3-ladder        # every ladder run under results/*/2026*; then read results/g3/ladder/summary.md
python3 scripts/lib/ladder_tables.py --results DIR --levers FILE --modelled FILE --out DIR
```

### Inputs: the contract with the ladder body (#51)

A **ladder run** is either a run dir `results/<gate>/<run-id>/` (with `manifest.json`) or a
cohort dir (`cohort.json` plus its members' run dirs) whose PARAMS name a rung. Cohort members
(`…-nN-rK`) are read only through their cohort.

**PARAMS** live under the `params` key of `manifest.json`. For a cohort they come from
`params` in `cohort.json`, or failing that from the rank-0 member manifest's `params`. Keys are
case-insensitive, and a leading `LAD_` or `AK2_` is ignored. A value outside its enum is a
DEFECT (contract), and the run is excluded.

| key | required | values |
|---|---|---|
| `rung` | yes | a rung of ladder.levers.tsv |
| `arm` | yes | `S` or `O` (must match the rung's arm in ladder.levers.tsv) |
| `cohort` | yes | integer ≥ 1 |
| `rep` | no (1) | integer ≥ 1 |
| `run_kind` | no (`ladder`) | `ladder` or `endpoint` |
| `state` | no (`cold`) | `cold`, `warm` or `cold-local`. Ladder runs must be cold. |
| `endpoint` | endpoint runs only | one or more of `S*-time`, `S*-cost`, `O*-time`, `O*-cost` on the run's own arm, separated by `;`. Empty on ladder runs. |

**The planned set.**
- For a single run, it is the manifest's `sample_accessions`. If that is empty, the manifest's
  `sample_accessions_ref` (`@project:a-b`) is resolved against the recorded
  `results/cohort/<project>/runs.tsv`.
- For a cohort, it is **cohort.json's own `sample_accessions_ref`**, as run-multi writes it, and
  never the union of whichever members wrote a manifest. Only when the spec used a literal list
  (cohort.json's ref is null) does it fall back to the first member manifest's
  `sample_accessions`; every member gets the same spec env.

If a run's set of lad-sample accessions differs from its planned set, that is a DEFECT
"incomplete" and the run is excluded. A run with no planned set is excluded the same way.

**Cohort members.** Every member of a cohort must have its manifest. A member that run-multi
recorded as `manifest: "missing"` (it never launched), a member whose manifest file is absent,
or fewer members than cohort.json's `nodes` is a DEFECT "incomplete: cohort member manifest
missing", and the cohort is excluded. A partial fleet's wall and bill are not the rung's.

**`lad-sample` lines.** For every classified sample, the body emits `lad-sample {json}` in the
run log (streamed) and appends the same object as one line of `out/lad-samples.jsonl` (pushed;
any depth under `out/`). The tables read the pushed file. A difference from the streamed lines
is recorded as a note. The streamed lines are used only if the file is missing.

Contract version 1:

| field | required | type | meaning |
|---|---|---|---|
| `v` | yes | int | exactly `1` |
| `arm`, `rung`, `cohort` | yes | | must equal the run's PARAMS |
| `accession` | yes | non-empty str | the run accession |
| `pairs` | yes | int ≥ 0 | read pairs classified |
| `rc` | yes | int (not a string) | the classify invocation's exit status; non-zero is a DEFECT "sample failed" and excludes the run |
| `t_start`, `t_end` | yes | number | epoch seconds (3 decimals) when the sample's work started and ended on the node, with `t_end` ≥ `t_start`. The model's per-sample span is the union of these intervals. |
| `phases` | yes | object | phase name → seconds, written with 3 decimals (ms granularity). A `sample:` lever phase must use names that appear here. |
| `outputs` | yes | object | role → `{"bytes": int, "sha256": "<64 lowercase hex, computed on the node>"}`. `output` and `report` are required; add `classified_1`, `classified_2`, `unclassified_1` and `unclassified_2` when they are written. The set of roles is the file set. |
| `s5` | yes | object | `{"status": "n/a"\|"identical"\|"differs", "fallback": "none"\|"gzip", "gz_sha256": [hex, ...], "rg_sha256": [hex, ...], "P": int, "nproc": int}`. `n/a` means the run does not use rapidgzip; the sha lists are then not read. Otherwise `status` is the identity phase's result for this input, and `gz_sha256` and `rg_sha256` are the sha256 of gzip's and of rapidgzip's decompressed output, one per input file in mate order (R1, R2). They must be equal-length lists of 64 lowercase hex: `identical` means the lists are equal, `differs` means they are not. `fallback` defaults to `none`. When `status` is `differs`, the body must decompress that sample with gzip instead and record `"fallback": "gzip"`. `differs` with `fallback: none` is a contract DEFECT, and so is `fallback: gzip` with any other status. |
| `rank`, `idx`, `input_bytes`, `threads` | no | | node rank, index in the cohort, input bytes, threads |

A missing or ill-typed required field is a DEFECT (contract) and excludes the run.

**`scripts/g3/ladder.levers.tsv`** (#51) is tab-separated with a header row. `#` lines are
comments. Columns are read by name:

| column | meaning |
|---|---|
| `rung`, `arm` | the rung and its arm |
| `predecessor` | the rung this one changes one lever from (empty or `-` for a root) |
| `lever` | the lever key-group. `stock` marks only the root S0-T1. S0-Tv's predecessor is S0-T1 and its lever is `threads`. S5's lever is `rapidgzip`, which is how the S5 findings find it. |
| `counterpart` | the O counterpart of an S lever, or the stated reason there is none |
| `phase` | the lever's own phase. `run:NAME` is a manifest phase; `sample:NAME` is the sum over the run's lad-sample `phases.NAME`; a bare `NAME` means run if the manifest has it, else sample. `A+B` sums the two. |
| `endpoint` | the endpoint(s) this rung is, for example `S*-time;S*-cost` (every cohort) or `c1:S*-time;c10:S*-time` (per cohort; a per-cohort declaration wins). Two rungs declaring the same endpoint for the same cohort is a DEFECT (levers). An endpoint that is not declared gives the status "endpoint not declared"; nothing is selected from the data. |
| `pred_wall_s`, `pred_usd`, `pred_phase_s` (optional) | the predicted delta on each axis, set against the threshold |
| `status` (optional) | empty for a run rung. `not-run: <reason>` (read from this column only) means the rung is not run, for example `not-run: no parameter change` for S3 when the tune probe chose `none`. It has its own deltas row labelled with that text and no numbers. Its successor's delta is taken against the **nearest run ancestor**, and labelled with that ancestor and with the skipped rung's text (deltas.tsv `predecessor_basis` and status; pairs.tsv lever-row note). The pairs skip the rung. A run on such a rung gets a note. |

The **stock rungs** are the S root whose lever is `stock` (S0-T1) and its `threads` child
(S0-Tv). They are the sources of pairs 1 and 2, and the candidates for the Law 1 reference.

**Modelled values** go in `results/g3/ladder-modelled.tsv` (`--modelled`), which
**`make g3-ladder-model`** writes (`scripts/lib/ladder_model.py`). Scott named c100 stock T1 as
modelled from c10's per-thread rate, and that is the default. For each cold c10 S0-T1 ladder run
that passes validation **and Law 1** (a run with any DEFECT cannot feed the model):
- P = its pairs, S = its per-sample span (the union of its lad-sample `[t_start, t_end]`
  intervals), and r = P / S, the per-thread rate at T1;
- the fixed part is F = wall − S. If F < 0 (S > wall) on any run, the model is refused;
- T1 is serial, so if any run's samples overlap the model is refused: that is, if the union of
  the spans is less than their sum minus 1 ms per sample. The test case is 10 concurrent samples;
- wall(c100) = F + P_target / r, where P_target is the `read_count` sum of `@PRJNA398089:1-100`
  in the recorded runs.tsv;
- billed(c100) = wall × price/h × nodes / 3600.

The value written is the median over those runs. The flags are `--rung`, `--from-cohort`,
`--to-cohort` and `--target-ref`. It exits 2 and writes nothing if no run qualifies.

The file's columns are `arm`, `rung`, `cohort`, `axis`, `value`, `basis`, `from_cohort`,
`target_ref`, `runs` (the run IDs used, comma-separated) and `source`. `source` is `<generator,
commit, run IDs, target> | path=sha256 path=sha256 ...`, covering every file read (each run's
manifest, lad-samples and util files, the runs.tsv and the lever table), with paths relative to
the repo.

g3-ladder checks every row in two ways. Any failure **refuses** the row as a DEFECT (modelled):
1. It re-hashes every cited file. A row that cites nothing, or whose files are missing or
   changed, fails.
2. It **re-derives the row**: it runs `ladder_model.model()` on the current record with the
   row's own rung, `from_cohort`, `cohort` and `target_ref`. The row must reproduce the value
   (to 1e-6 relative) from exactly the same set of runs. This catches a hand-entered or edited
   value even when it cites real files, and a stale model (the qualifying runs changed since it
   was written).

A modelled row is used only where a (rung, cohort) has no measured run on that axis. Where
measured runs exist, it is ignored and a note says so. A used row appears in rungs.tsv with basis
`modelled (flagged): …`. Any delta or pair total that uses it is labelled "modelled (flagged):
not a measurement, not resolvable", and the pair note says the source (or target) is "a modelled
value (flagged: not a measurement)".

**Utilisation** comes from the **fleet** row of the run's (or cohort's) `tables/util.tsv`, as
written by `make util` (docs/util.md). If there is no fleet row (a node row alone does not
count) or no file, the utilisation is reported as missing. It is never imputed, and this target
never generates it.

### Definitions

- **wall_s**, end to end: from the first `instance.launch_time` to the last
  `instance.terminated_at` over the run's nodes. If either is missing on any node, wall is
  missing and a note says so. Manifest `start` and `stop` are not used as a fallback.
- **billed_usd**: the manifests' `cost_usd`, summed over a cohort. If any node lacks it, billed
  is missing.
- **lever_phase_s**: the rung's lever phase, measured the same way on the rung and on its
  predecessor. For a `run:` phase, each node's entries are summed and the max over nodes is
  taken.
- **Median and range** are taken per (arm, rung, cohort) over the runs in the attribution. The
  median of two runs is their mean. Range = max − min, shown only for n ≥ 2.
- **Instrument granularity q**, per run:
  - wall: 2 s (two whole-second timestamps);
  - billed: price/h × 2 s / 3600 × nodes;
  - run phase: 1 s × the number of summed manifest phase entries;
  - sample phase: 0.001 s × the number of summed lad-sample entries;
  - effective cost: q_billed ÷ U.

  A group's q is the largest of its runs'. If any run's q is unknown (no price, say), the group's
  q is unknown.
- **Resolution.** A delta (rung median − predecessor median) is **resolved** only if |Δ| > 2 ×
  max(range of the rung, range of the predecessor, q). Every other delta is **unresolvable**,
  with the reason:
  - "below instrument granularity", when q is the larger term;
  - "|delta| <= 2 x spread";
  - "n < 2";
  - "instrument granularity unknown".

  An unresolvable delta is never reported as a null. `measured_spread`, `granularity_q`,
  `threshold` and `predicted_delta` sit beside it, together with `predicted_resolvable`, which
  says whether this probe could have resolved the predicted effect.
- **Effective cost per resource** = util.tsv's fleet `cost_usd` ÷ U. That cost covers the same
  node set as U. It is computed for U_cpu, U_mem_mean, U_net at baseline and peak, and U_net for
  each direction (rx, tx). The resources are never combined. U = 0 gives `inf`. effcost.tsv and
  pairs.tsv carry util coverage.
- **The three pairs** are computed per cohort, on the declared endpoints:
  - S vs S\* and S vs O\*, from each stock rung;
  - S\* vs O\*.

  The time endpoint is compared on wall_s. The cost endpoint is compared on billed_usd and on
  each effective cost.
- **Pair totals and lever rows.** An endpoint's total comes from its cold endpoint runs (those
  with `run_kind` endpoint, the tag, and the declared rung) where any exist; otherwise from the
  rung's ladder runs. A cold endpoint run whose rung is not the one declared for its tag and
  cohort is not used, and a note names it. Each total row carries its resolution label, the source/target ratio and
  the endpoint basis. Beside it are its lever rows: the rung deltas along the target's
  predecessor chain back to the source.
- **The residual** is total − Σ(lever deltas). When both totals are the values the lever rows
  use (ladder medians, or a flagged modelled value), the lever deltas telescope, so the residual
  is an identity (0). It checks the arithmetic, not the physics. When a total comes from endpoint runs, the residual is the difference between those
  runs and the ladder's chain of medians. If the source is not on the chain, the total is
  labelled "not an attribution".
- **Excluded from the attribution.** Every run still has a row in runs.tsv, with the reason.
  The exclusions are:
  - any DEFECT on the run: contract, PARAMS, incomplete (including a missing cohort member),
    sample failed, or Law 1 (a mismatch, a missing stock reference on the O arm, or an O-arm
    `differs` with no matching S `rg_sha256`);
  - non-cold ladder runs.

  Endpoint runs feed the pair totals (cold) and endpoints.tsv (every state).
- **Law 1 across arms**, per accession. Each successful, contract-clean sample's role set and
  sha256 are compared against the **reference**: the first S-arm entry, stock rungs first.
  - A different role set or sha256 is a **DEFECT**, and the run is excluded.
  - If the accession has no S-arm entry, the status is "no upstream reference", never
    "identical".
  - If an accession appears on the O arm and has no stock reference, that is a DEFECT.
- **S5's rule.** Under the fallback rule, every `differs` entry carries `fallback: gzip`, so its
  outputs come from gzip's input and it is compared normally under Law 1. The run stays
  measurable and in the attribution. A `differs` entry without the fallback is a contract DEFECT.
  - summary.md reports a finding against each rapidgzip rung (S5 and its descendants on ladder
    1): "S5 not output-preserving on N of M inputs (fell back to gzip)".
  - **S entries that disagree** with each other on `rg_sha256` for the same accession (the loss
    depends on -P) are flagged as a finding. This is not a DEFECT.
  - **An O-arm `differs` entry** must match an S `differs` entry's `rg_sha256` for the same
    accession; otherwise it is a DEFECT and the run is excluded.

  Every `differs` entry is a row of s5-nonpreserving.tsv, with its `rg_sha256`, its Law 1
  status and the S5 check.

### Outputs (`results/g3/ladder/`)

| file | what |
|---|---|
| `runs.tsv` | one row per ladder run: PARAMS, type, nodes, commit, price, wall_s, billed_usd, lever phase, planned and emitted samples, U_* (cpu, mem mean and peak, net baseline/peak and each direction), util cost_usd, each effective cost, util coverage, whether it is in the attribution (with the reason if not), notes |
| `tidy.tsv` | long rows: run-level metrics plus every lad-sample field (pairs, rc, phase.*, output.<role>.bytes and .sha256, s5.status, s5.fallback) |
| `rungs.tsv` | per (arm, rung, cohort) and axis (wall_s, billed_usd, lever_phase_s): basis (measured or modelled), n, median, min, max, range, granularity_q |
| `deltas.tsv` | each rung against its predecessor (or its nearest run ancestor, `predecessor_basis`) on the three axes: ranges, measured spread, q, threshold, status, predicted delta and whether it was resolvable; a `not-run` rung's row carries its label |
| `effcost.tsv` | per (arm, rung, cohort): median and range of each U and each effective cost, with q, util coverage, and any missing util named |
| `pairs.tsv` | the three pairs × cohort × axis: lever rows, then the total row (sum of lever deltas, residual, ratio, endpoint basis, util coverage) |
| `law1.tsv`, `law1-detail.tsv` | per accession, and per accession × run × role: the sha256 against what it was compared with, and the status |
| `s5-nonpreserving.tsv` | every `differs` entry (both arms): fallback, P, nproc, `rg_sha256`, whether its outputs equal the reference, its Law 1 status, and the S5 check (S rapidgzip output, disagreement flag, or the O-arm match) |
| `endpoints.tsv` | the endpoint runs: per (arm, endpoint, rung, cohort, state = cold, warm or cold-local), with wall, billed and each manifest phase (n, median, range) |
| `spend.tsv` | every ladder run's billed $, whether `results/g3/campaign/spend.tsv` has it, and the total |
| `summary.md` | counts, exclusions, DEFECTs, findings against levers, notes, and each pair total (with the endpoint basis) followed by its per-lever rows (rung, delta, status). Generated, and cites only the tables. |
| `manifest.json` | the generator, its commit and dirty flag, every input with its bytes and sha256 (only ladder runs' files, the lever and modelled tables, and any runs.tsv used), every output's sha256, the runs with their PARAMS, DEFECTs, findings and notes |

**Spend.** `g3_campaign.py` (`make g3-tables`) already counts ladder runs under `results/g3/`:
single runs, and cohorts through their members' manifests. It also counts ladder dirs under any
other gate, recognised by a `params` entry that names a rung. In this target's `spend.tsv`, any
ladder run missing from the campaign total is marked `NO`, and a note is added.

**Failure looks like:** `ladder_tables: DEFECT (<class>): …` on stderr, with exit 1. The classes
are `Law 1`, `contract`, `incomplete`, `sample failed` and `levers`. For a Law 1 DEFECT,
law1-detail.tsv has both sha256 values. runs.tsv's `in_attribution` gives the reason for each
excluded run.
