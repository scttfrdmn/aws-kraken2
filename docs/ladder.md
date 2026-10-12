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
exactly one rung (`endpoint`, `c<cohort>:<endpoint>;...`). An alias's candidates are run (or alias)
rungs with the alias's predecessor and group, or the predecessor itself. An `alias_cohorts` entry
names another run rung of the same arm, on a rung whose status is `run`, and at a cohort that is
not also in its `not_run_cohorts`. On the committed table, every `alias_cohorts` declaration whose
two rungs resolve under the committed `ladder.resolved.tsv` must be one configuration. The module is
importable (`load`, `check`, `resolve`, `changed`, `coupled_keys`, `spec_params`, `config_row`,
`alias_cohort_problems`, `bracket`) for #53's `ladder_check.py`.

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
rung as its winner's runs, as they do (`scripts/tests/ladder_levers_tables_test.py` checks it with
real alias rows in a synthetic record). S\*-cost and O\*-cost are chosen by the **lowest median billed $** (Scott, 2026-10-10);
effective cost per resource is still reported for every endpoint.
**Ladder 2 runs twice** (Scott, 2026-10-10): the time side O0 … O5 from `Sstar-time`, with O3's N
chosen among candidates bracketed by the fit, and the cost side O0-cost … O5-cost from `Sstar-cost`, with its own
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
that inherits it. `scripts/g3/ladder.resolved.tsv` (columns origin, cohort, key, value, source,
and the cites, margin and note that `make ladder-select` writes; "Selection", below) resolves a
token per cohort. The generator refuses any rung with a placeholder left, and refuses a resolution
when:
- its source is not an existing `results/…` path inside a run or cohort dir (a directory below
  `results/` holding `manifest.json` or `cohort.json`);
- any of its cites (`path=sha256`, space-separated) is not a `results/…` file, does not exist, or
  no longer hashes to its sha256;
- it resolves S4 with neither THREADS nor PROCS as a `vcpus/<k>` ratio;
- after resolving, the one-lever check, run again on the resolved values against the resolved
  predecessor, fails: the rung is identical to its predecessor (mark it not-run instead), or it
  changes another key-group. THREADS, PROCS and INFLIGHT are compared as numbers, each resolved
  with `vc()` at its own rung's host (vCPUs from the type's size), so `THREADS=96, PROCS=vcpus/96`
  on x8g.24xlarge is S2a's `THREADS=vcpus, PROCS=1` and is refused. The same text on two hosts is
  a derived move with the host's own lever (the `derived` column), not a second lever;
- an alias's winner is not one of its `alias_of` candidates, or is a candidate not run at that
  cohort (the alias's own predecessor excepted);
- its note names a rule sha256 (`rule sha256 <hex>`, as make ladder-select writes it) that is not
  the sha256 of the rung's `select` text now: the rule changed after the selection;
- any `alias_cohorts` declaration at that cohort whose two rungs both resolve but differ (below).

Every refusal is a `ladder_levers: refused: …` message with exit 3, never a traceback. A resolution
row for a rung at a cohort where it is not run (`not_run_cohorts`) is never used, so it draws a
warning (`ladder_levers: warning: … is ignored`).

**Not run at some cohorts** (`not_run_cohorts`, `c<cohort>: <reason>;...`): a rung whose selection
has a single candidate at a cohort, its predecessor's own configuration, is not run there. Its
tokens then resolve to that predecessor's values, so its descendants stay determined. The entries
are allowed on a selecting rung, on a candidate rung, and on a rung whose values derive from a
selection (an `@select` token). At c1:
- S4 and S8: P and K are at most the cohort, so P = 1 with T = vcpus (S2a's) and K = 1 (S7b's).
  At c1, S5's run predecessor is therefore S2a, and S9's is S7b;
- O1 and O1-cost: N = S8's K = 1, which is O0b's (O0b-cost's) own configuration;
- O4b and O4b-cost: INFLIGHT 1 … vCPUs / THREADS with THREADS = vcpus leaves only 1, O4a's (O4a-cost's);
- the candidate rungs whose value the cohort excludes: every S4-t\<T\> (P = 96 / T > 1), S8-k2,
  O2-x8g and O2-cost-x8g (O1's own type at c1).

The tables must skip a rung at the cohorts it lists, as they skip `status: not-run`.

**The cost chain reads the time chain where they coincide** (`alias_cohorts`, `c<cohort>:
<rung>;...`; Scott via the coordinator, 2026-10-11). At a cohort where a cost-chain rung's resolved
PARAMS and host equal its time-chain counterpart's (its name without `-cost`), it is not run. It is
`alias: same configuration as <rung> at c<C>` there and reads that rung's runs.
- At c1 these are O0-cost (O0) and O0b-cost (O0b), because both S\* endpoints chose S9, and
  O2-cost-r8g (O2-r8g).
- **The generator** refuses to generate a rung at a cohort where it is aliased ("no spec is
  generated for it; <rung>'s runs are read"). It refuses any generation at a cohort where a
  declaration whose two rungs resolve differs in any PARAM or the host. It refuses a cost rung
  whose resolved configuration equals its time counterpart's without the declaration ("declare
  alias_cohorts 'c<C>: <rung>'"), so a coincidence that a later selection creates (O3-cost's N
  equal to O3's, say) cannot run twice.
- `make ladder-check` (`ladder_levers.py check [TSV] [--resolved RES]`) verifies every declaration
  that resolves. It checks any table it is given, under the committed `ladder.resolved.tsv` or
  `--resolved`.
- **The tables verify each pair before reading the target's runs** (`alias_cohort_checks`). They use
  the generator's own rule, on the lever table's values resolved under `ladder.resolved.tsv`'s
  rows:
  - a pair whose configurations differ is a DEFECT (levers);
  - a pair that cannot be resolved there is not verified.

  Either way the rung is "alias unresolved" at that cohort, reads no runs, and a note says so.
- **A verified pair:** the rung reads the target's runs (rungs.tsv basis "alias: same configuration
  as O0 at c1 (alias_cohorts)"). Its delta is taken against its own predecessor, and the pairs skip
  it when the two read the same runs. A run of the rung itself at such a cohort is not used, and a
  note says so.

**Selection rules** (the `select` column, registered before any run; every `@select:<rung>`
selection has one, and a rule names the candidates, the axis and the ties):

| rung | candidates (alias_of) | axis | ties |
|---|---|---|---|
| S4 (alias) | S2a (P = 1, T = vcpus) and S4-t48, -t32, -t24, -t16, -t12, -t8, -t6, -t4, -t3, -t2, -t1: T threads × 96/T processes on x8g.24xlarge, P ≤ cohort (`not_run_cohorts` where 96/T > cohort); recorded as THREADS=T, PROCS=vcpus/T | median wall_s | fewer processes |
| S8 (alias) | S7b (K = 1) and S8-k2: K = 1 … min(cohort, the free X quota in x8g.24xlarge); the X quota is 256 vCPUs, 2 nodes (a raised quota adds S8-k\<K\> rows) | median wall_s | fewer nodes |
| Sstar-time | S9, Sstar-r8g, Sstar-r8gd (alias) | median wall_s | fewer vCPUs |
| Sstar-cost | S9, Sstar-r8g, Sstar-r8gd (alias) | median billed_usd | fewer vCPUs |
| O2 / O2-cost (alias) | O1 (O1-cost), O2-r8g (O2-cost-r8g, r8g.48xlarge), O2-x8g (O2-cost-x8g, x8g.24xlarge): per family of c8g, c9g, r8g and x8g, its smallest type that holds 1/N of the table at O1's N (metal twins excluded; c8g and c9g end at 384 GiB); the rows are N = 1's, not run at c10 and above until S8 gives N there | median wall_s / billed_usd | fewer fleet vCPUs |
| O3 / O3-cost (alias) | O2 (O2-cost) and O3-n2, -n4, -n8, -n16, -n32 (O3-cost-n…): N = K shards, **each on the smallest non-metal type of O2's winning family that holds table/K by `fits()`** (Scott, 2026-10-11, #25; below); **bracket:** per cohort, the N within a factor 2 of fit R's time- (cost-)optimal N over {1, 2, 4, 8, 16, 32}, each N predicted on its own type (`results/g3/fit26/predictions.tsv`), widened to all of them where that prediction is not "within data" or a type has none | median wall_s / billed_usd (measured, not the fit) | fewer nodes |
| O4b / O4b-cost | INFLIGHT 1 … vCPUs / THREADS on O3's type, memory permitting (no candidate rungs yet: below) | median wall_s / billed_usd | fewer in flight |

**Candidate rungs** (Scott via the coordinator, 2026-10-11). Each selection is an alias over its
candidates, as S\* is:
- each candidate is a run rung named `<rung>-<short value>` that changes only the selecting rung's
  key-group from the same predecessor. The names live in `ladder.levers.tsv` only (its rows and
  `alias_of`), so a rename is an edit of that one file;
- the predecessor counts as a candidate. A predecessor not run at the cohort stands for the
  configuration it has there (O1 at c1 is O0b's);
- `@select:<alias>[:KEY]` resolves any key to the winner's value (`_values`), so S5 takes S4's
  winner's THREADS and PROCS, and O3's candidates (`instance @floor:O2`) take the smallest type of
  O2's winner's family that holds table/K (below).

**O2 is one candidate per family** (Scott, 2026-10-11, #25; in the rule text): the family's smallest
type holding 1/N of the table (the #26 fit's memory floor), metal twins excluded.

**O3 is right-sized per N** (Scott, 2026-10-11, #25). Each O3-n\<K\> and O3-cost-n\<K\> has `instance
@floor:O2` (`@floor:O2-cost`).
- **The type** is the smallest non-metal type of O2's winning family, from
  `scripts/g3/ladder.types.tsv` (written and checked by `make ladder-types`, below), that holds the
  rung at that cohort by `fits()`. That is the engine
  shard table/K × 1.15 + 8 GB + 7.5 GB per sample in flight, the inputs and outputs, and 16 GiB of
  slack, with every other PARAM as resolved. The types table holds the families' types, vCPUs and
  memory from truffle on 2026-10-11.
- **At c1 and INFLIGHT = 1:**
  - x8g: x8g.12xlarge at 2, x8g.8xlarge at 4, x8g.4xlarge at 8, x8g.2xlarge at 16 and 32;
  - r8g: r8g.24xlarge at 2, r8g.12xlarge at 4, r8g.8xlarge at 8, r8g.4xlarge at 16 and 32.
- **The one-lever check counts the host change as derived.** It moves with SHARDS inside O3's lever,
  as S4's vCPU ratios move with the host. It is declared in the `derived` column as an `instance:
  …` clause, and `derived_host` honours the clause only in two cases:
  - the rung's instance is `@floor:<its own predecessor>`;
  - the rung is an alias whose instance is `@select:<itself>` and every candidate other than its
    predecessor qualifies.

  Any other host change is the HOST group and is refused, clause or not. The tests refuse three
  cases: S5 with a changed host plus the clause, `@floor:Sstar-time` on O3-n2, and a fixed
  c8g.48xlarge on O3-n2. The last two also stop the O3 alias from qualifying.
- **O3's delta includes the host right-sizing.** Each N runs on its own type, so O3's delta is not
  the shard count alone: the vCPUs, the memory and the network change with N as well. deltas.tsv
  (`predecessor_basis`) and the pairs.tsv lever row (`note`) say so on O3 and O3-cost: "the delta
  includes the per-N host right-sizing (…)".
- **The O3 alias's own host** is `@select:O3`, its winner's host, also declared as derived. So O4a
  and O5 (`=pred`) inherit the winner's right-sized type.
- **The bracket's grid is the candidates' N:** {1, 2, 4, 8, 16, 32}, where 1 is O2's own N at
  K = 1. 64 is dropped rather than an O3-n64 added. The candidate rows end at 32, as the
  coordinator set them, and a grid with an N that no row has is refused.

**The types table** (`make ladder-types`, `scripts/g3/ladder-types.sh`, `scripts/lib/ladder_types.py`):

```bash
make ladder-types           # rewrite scripts/g3/ladder.types.tsv from truffle (read-only: nothing is launched)
make ladder-types CHECK=1   # compare the committed table with truffle's answer now; exit 1 on any difference
```

- **Write** queries `truffle find 'c8g.*' 'c9g.*' 'r8g.*' 'x8g.*' --regions us-west-2 --show-price -o
  json` and keeps the four families exactly (no d, b or n variants): type, vCPUs, memory and the
  on-demand price. It records `truffle version`, the query and the time in the header (truffle
  0.57.1 on 2026-10-11).
- **Check** compares every type, vCPU count, memory and price, and reports both truffle versions.
- `make test` runs `ladder_types.py validate` offline. It checks the shape, that each family has a
  non-metal type, and that the header records the version and the query.
- The table is under `scripts/g3/`, so it must be committed before the next launch.

**What the registered rules leave open:**
- **N = 2 rows for O2:** O2's rows for N = 2 (r8g.24xlarge, x8g.12xlarge) wait for S8 at c10 and
  above.
- **O4b:** its candidates (INFLIGHT up to vCPUs / THREADS on O3's type) depend on S4's T and on
  O3's type, which no cohort above c1 has resolved yet. O4b and O4b-cost therefore stay selecting
  rungs, not run at c1. Their candidate rows are added once S4 and O3 are selected at a cohort.

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
- engine: the engine's classify phase, up to its exit. The exit time is recorded by `lad_engine`'s
  subshell as the engine exits (`eng.end`), not when the watch loop next notices. A hash made
  after the exit is therefore uncovered, to within the few ms that writing the file takes.

**Uploads cover too (NB1).** The node's end waits for its uploads either way, so an upload cannot
leave the hash critical either. The covering spans therefore also include:
- each done upload of the session: a row of lever.sh's `uploads.tsv`, `[t_start, t_end]`;
- in an overlap session, the one upload in flight: from the later of the last row's end and its own
  enqueue, exact to the lane's 0.2 s poll.

A hash is critical only if neither a classify span nor an upload covers it. So:
- a hash done after the last classify ended, with no upload in flight, is all critical, and the
  last sample's hash is unless an upload covers it;
- a hash done while another sample classifies, or while an upload is in flight, is not;
- with one lane under a serial upload mode, the lane is idle and nothing is uploading while it
  hashes (the upload follows the hash in the same shell), so each hash is critical.

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
- **Exact** for the per-sample path with one lane (serial or overlap upload), for O5, and for the
  engine at N = 1.
- **Conservative: an upper bound on the true net wall** in two cases, both subtracting less than
  the hashes cost:
  - the engine at N > 1, where a node's hash can hold up the fleet while only its own classify
    span is counted as covering;
  - a serial upload mode with several lanes, where a hash covered by another lane's classify span
    still holds up its own lane.

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

`make ladder-campaign COHORT=<c>` runs one cohort in this order ("The campaign", below).

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

Generated and committed at c1 (every rung fully determined there, 18):
- the S rungs (15): S0-T1, S0-Tv, S1, S2b-i, S2b-ii, S2d, S2c, S2a, S5, S6, S7a, S7b, S9, Sstar-r8g,
  Sstar-r8gd;
- the O rungs (3), since the S\* aliases resolved to S9: O0, O0b and O2-r8g.

All of them pass `DRY_RUN=1` (user data, cost and quota checks):
`results/rehearse/dryrun-userdata-*-<sha7>.tsv`. The other O rungs are not generated at c1, for
these reasons:
- O0-cost, O0b-cost and O2-cost-r8g are aliases there;
- O1, O1-cost, O4b, O4b-cost, O2-x8g and O2-cost-x8g are not run there;
- O3's candidates, O4a and O5 wait for O2's selection (O2-r8g's runs). The cost side waits the
  same way for O2-cost's.

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
  whenever a shim is in use. Ours-plain runs with every `AK2_ENGINE_*`, `AK2_COHORT` and
  `AK2_COHORT_CHECK` removed from its environment. `make run` gives every cohort node
  `AK2_ENGINE_N`, `_RANK` and `_RENDEZVOUS`, and ours takes the engine path whenever
  `AK2_ENGINE_N` is set: resident shards, with `--memory-mapping` ignored. At 843e958, O0 at c1
  inherited them, read a second, anonymous copy of the 1.1 TB tmpfs table, and was OOM-killed
  (rc 137) during the load. `make ladder-stream-test` case P checks the strip, and its mutation
  restores the leak. **Engine path:** one cohort-mode process per node over the replica's
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
  - rapidgzip exits non-zero;
  - GNU gzip exits other than 0 or 2;
  - or either output is empty (the empty-stream sha256, e3b0c442…).

  **GNU gzip's exit 2 is a warning** (Scott, 2026-10-11), for example "trailing garbage ignored":
  its output is complete, and upstream's wrapper ignores the status, so stock reads the full
  stream. By itself it is neither a difference nor an input defect. It is recorded as
  `gz_warning: true` in the identity line, and as `s5.gz_warning`, a boolean list per mate.

  The lad-sample `s5` carries `gz_exit`, `gz_warning` and `rg_exit`, lists per mate, whenever status
  is not n/a, beside the sha lists. If GNU gzip itself exits other than 0 or 2, or gives an empty
  stream, the identity line has `input_defect: true`. That is an input or staging DEFECT, not an S5
  finding (the input passed its sha256 against the staged metadata). A sample that differs gets `s5.status: differs`
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
The full local rehearsal is #53 ("The rehearsal", below).

**Not covered locally:** real NVMe devices (`lv_nvme` uses its seam), real S3 and RODA, and an
instance's CPU count and memory (the rehearsal's VM has 8 vCPUs and 8 GiB).

## Body changes and finished runs

Every spec embeds the body in `command[2]`, with the rung's parameter block in place of `@PARAMS@`.
So a change to `scripts/g3/ladder.body.sh` changes every spec's sha256. Without a declaration,
the campaign's done check would rerun every finished run, including those on arms the change cannot
affect.

```bash
make ladder-respec                 # regenerate every committed runs/g3-l-*.json (COHORT=<n> for one cohort); prints what changed beyond the body
make ladder-compat-check           # every ladder.body-compat.tsv row against git history, with its hunks; and no spec is stale
```

Both run in `make test`, with `ladder-stream-test` case X.

**The declaration.** Each row of `scripts/g3/ladder.body-compat.tsv` (`scripts/lib/ladder_body_compat.py`)
gives:
- `from_body_sha256` and `to_body_sha256`: sha256 of the body file;
- `commit`, which must hold the `to` version;
- `unaffected` and `affected`: comma lists of classifiers, splitting `upstream`, `ours-plain` and
  `ours-engine`;
- `functions`: where every changed line is;
- `reason`.

`check` refuses a row in any of these cases:
- a version is not in git history;
- `commit` does not hold `to`;
- the two lists do not partition the classifiers;
- any changed line is outside the block that `ladder-stream-test` drives (between its "load and
  classify" and "end of the functions" markers), or outside the row's functions.

Case X then runs both versions for every classifier under a cohort node's engine env. The
invocations (argv and the `AK2_*` env) must be identical for each unaffected classifier, and must
differ for each affected one.

**The done check.** A finished run whose `spec_sha256` is not the committed spec's still counts
when all of the following hold:
- its member `spec.json` hashes to that `spec_sha256`;
- it differs from the committed spec only in the body; the parameter block and everything outside
  `command[2]` are byte-identical;
- a chain of rows from its body to the committed body names its classifier unaffected.

The plan prints the cited row. Any other difference reruns the run. `make ladder-campaign-test`'s
compat scenario covers each refusal: an affected classifier, an undeclared change, a TTL change,
a `spec.json` that is not the recorded bytes, and a row that does not cover the run's classifier.

**The row at 9126a6f.** `lad_one` strips the engine env from ours-plain. Upstream's invocation is
unchanged, and ours-engine never calls `lad_one`. So S-arm and engine runs at 843e958 still count,
and O0 (ours-plain) reruns.

## The campaign: `make ladder-campaign`

**What:** every committed ladder spec of one cohort, `REPS` times, in the run order above,
through `make run`, with the after-run checks. It commits nothing and pushes nothing.

```bash
DRY_RUN=1 make ladder-campaign COHORT=1        # the plan for the record: no AWS call, nothing written in the repo
make ladder-campaign COHORT=1                  # the campaign (REPS=2, CONCURRENCY=1)
make ladder-campaign COHORT=1 RUNGS=S1,S5      # a subset, by rung name
make ladder-campaign COHORT=1 CONCURRENCY=2 FAMILY_LIMITS=X=1,Standard=2   # see "Concurrency" first
make ladder-campaign-test                      # the stub test (no AWS; in make test)
```

`scripts/g3/ladder-campaign.sh` (`set +e`, logs `$-`) runs `scripts/lib/ladder_campaign.py`.

**Run it so it outlives the terminal.** A campaign takes hours. Run it in tmux (`tmux new -s
ladder`, then the command; detach with `C-b d`), or under nohup:

```bash
nohup make ladder-campaign COHORT=1 > results/g3/ladder-campaign/nohup-$(date -u +%Y%m%d-%H%M%S).out 2>&1 &
```

The campaign leaves SIGHUP alone, so nohup's ignore holds. INT and TERM stop it cleanly (below).
Each driver runs in its own session and writes to its own log file, not to a pipe of the
campaign's. So if the campaign itself is killed, the runs in flight finish on their own and
write their records; run `make orphans` afterwards.

**The plan.**
- **Specs:** every committed `runs/g3-l-*-c<C>.json` whose PARAMS block names cohort C. An
  uncommitted one is listed and not planned. NODES is the spec's WANT_N, which must be REPLICAS ×
  SHARDS.
- **Cost:** a rung's cost is the median billed `cost_usd` of its done runs at this cohort, if it
  has any (measured). Otherwise it is the spec's `cost_limit` × NODES: the generator's TTL ×
  on-demand price, an upper bound (estimate). No price is fetched.
- **Order:** rep 1 is cheapest first, with ties in ladder order (the rows of
  `ladder.levers.tsv`). Rep 2 is rep 1 reversed, and any rep k is reversed when k is even. The
  order is fixed when the campaign starts.
- **Skips:** a (rung, cohort, rep) is skipped if the record already has a **done** run of it.
  That is a cohort dir, or a single run dir that is not a cohort member, under
  `results/<gate>/<yyyymmdd>-*` (any year), such that:
  - its `spec_sha256` (rank 0's manifest) is the sha256 of the committed spec, and its `params`
    equal the spec's PARAMS on every key but `source`, `rep` and `rep_source`;
  - its record is clean:
    - every member exited 0 and has `own_gone: true`;
    - the cohort ended `members done` without fail fast;
    - `prefix_fetched` is true;
    - there are no sweep failures and no multipart-abort failures;
    - the scoped orphan check is 0. That is `orphans_rc` where `orphans_scope` is `own`. For older
      cohorts, whose `orphans_rc` is the global check that a concurrent run fails, it is the
      members' `own_gone`;
  - `ladder_tables` keeps it in the attribution: `in_attribution` is `yes` in its `runs.tsv`;
  - neither its id nor a member's id is in `scripts/lib/g3_defects.tsv`.

  Its rep is `params.rep`, or 1 if it has none. So S2a's first run
  (`results/g3/20261011-042400-f72142e-34a4-n1`, no `rep`) is S2a rep 1. The plan lists every
  ladder run of the planned rungs with every reason it is or is not counted. For the plan,
  `make g3-ladder OUT=<scratch dir outside the repo>` gives the attribution. Without its summary
  line the plan is refused (exit 3).

**Rep in the record.** `AK2_LADDER_REP=<rep>` is set in the env of each `make run`. run.sh and
run-multi.sh check it and record it as `params.rep`, with `rep_source`, in every manifest and in
`cohort.json` (docs/run.md, "Launch overrides"). The spec is the same file, byte for byte, for
every rep: `spec_sha256` shows that rep 2 ran the configuration that rep 1 did. No spec is
generated, so the tree stays clean and committed.

**Concurrency: one run at a time by default.** Runs in flight at once share S3 and RODA, the
database bucket every rung stages from, and the launch host. One run's staging would then slow
another's, and a rung's measured wall and its delta against its predecessor would include that
contention. That confounds the per-lever attribution (Laws 2 and 5). So `CONCURRENCY` defaults to
1. Above 1, these also apply:
- `FAMILY_LIMITS` caps the instances in flight per on-demand quota family (the mapping of
  `quota_check.sh`). It defaults to 2 for every family, including X. A run larger than its
  family's limit runs only when the family is otherwise empty;
- until a run of this campaign succeeds, nothing else is in flight (the cheapest rung runs first,
  alone).

Raise CONCURRENCY only for runs whose timings are not being compared.

**Launching.** `make run GATE=g3 SPEC=<spec> NODES=<WANT_N>`, one launch at a time. A launch
waits until all of these hold:
- the previous launch has settled: its driver has exited, or every member manifest records
  `.launch` (so the next quota check sees its instances);
- fewer than CONCURRENCY runs are in flight, and the family and first-run rules above hold;
- the rung's earlier rep has ended;
- `quota_check.sh REGION TYPE NODES` exits 0. Exit 2 (cannot judge) stops launching. Exit 1 is
  read from quota_check's own record (its JSON on stdout, else its message):
  - **the request alone exceeds the quota** (requested vCPUs > the quota): permanent. The rung stops
    at once and is reported ("exceeds the X on-demand quota of 256 vCPU on its own"). The rest of
    its family is still asked in the same pass;
  - **the request fits but running instances fill the quota:** wait. The family is asked again
    after 60 s, for at most `AK2_CAMPAIGN_QUOTA_MAX_WAIT_S` in total per item (default 6 h).
    After that the rung stops. The clock counts only the time between refusals during which none
    of the campaign's own runs of that family is in flight, to within the retry interval. A wait
    on its own sibling runs is the schedule, not the quota.

The tree must be clean under run.sh's paths before every launch; otherwise launching stops.

**After each run:**
1. `make orphans`. A finding is informational while other campaign runs are in flight. With
   nothing in flight it is a hard stop: no further launches, exit 3.
2. `make g3-ladder OUT=results/g3/ladder-campaign/<ts>/tables`. It counts as judged only if its
   log has the summary line `ladder_tables: N ladder run(s), … DEFECT(s) -> …`, which ladder_tables
   prints last, after every table is written. A DEFECT and a traceback both exit 1 (2 under make),
   so the exit cannot tell them apart. No summary line is a hard stop: Law 1 was not judged. A
   `DEFECT (Law 1)` line is a hard stop. Other DEFECT classes do not stop the campaign, for
   example the refused S2a launch's incomplete and contract DEFECTs.
3. **The outcome, judged from the record**, not from make run's exit. run-multi.sh's exit can be
   non-zero for reasons that are not the run's own. A run is `ok` when:
   - its cohort.json and member manifests pass the done check's record rules;
   - every member's `instance.az` is the AZ asked for;
   - the tables keep it in the attribution.

   Otherwise it is `capacity`, `quota` (run-multi refused for quota before any launch: queued
   again, up to 3 times) or `fail`, with every reason.
4. A row in `results/g3/ladder-campaign/<ts>.tsv`: `t, rung, rep, az, run_dir, exit, cost_usd,
   class, note`. `exit` is make run's. There are also `skip` rows (one per skipped item, at the
   start) and `not-launched` rows.

Before the first launch, the campaign runs both checks with nothing in flight. It refuses to start
on a finding, on a Law 1 DEFECT already in the record, on a g3-ladder without its summary line, or
on a dirty tree. Runs in flight when the campaign stops run to their end and are recorded; nothing
is terminated early. The exception is INT or TERM to the campaign: it passes TERM to each driver's
process group (run-multi.sh's finish trap then terminates its instances), waits for them, and runs
the final orphan check. A quota wait with nothing in flight lasts until the quota frees.

**Failures.**
- **InsufficientInstanceCapacity** (in the driver's output, a member's `launch.err` or a rank
  log) gives a capacity row: `<cohort id>`, `capacity: InsufficientInstanceCapacity in <az>
  (<type>, <rung> c<C> rep <r>; make ladder-campaign <ts>)` and its evidence.
  - The row goes in `<ts>.defects.tsv` at once. It is appended to `scripts/lib/g3_defects.tsv`
    only when the campaign ends: a change under `scripts/` during the campaign would make run.sh
    refuse every later launch.
  - The item is then retried once, at the front of the queue. The AZ is the first one in
    `scripts/g3/ladder.azs.tsv` for the type that has not been tried and whose evidence (a
    git-tracked manifest of that type in that AZ) holds. The retry carries `AK2_LAUNCH_AZ` and a
    reason naming the failed run, and is recorded as `launch_override`.
  - With no such AZ, or on a second capacity failure, the rung stops. x8g.24xlarge has
    us-west-2c, 2b and 2a on record. r8gd.48xlarge and r8g.48xlarge have only us-west-2b, so a
    capacity failure on them stops the rung and is reported.
- **Any other failure** stops that rung: its later reps are logged `not-launched`. The other
  rungs carry on.

**Outputs:**
- `results/g3/ladder-campaign/<ts>.plan.txt`: the plan as printed;
- `<ts>.tsv`: the campaign log;
- `<ts>/`: each launch's driver output (`<rung>-rep<r>[-<az>].log`), each orphan and g3-ladder
  check's output, and the latest tables (`tables/`).

Progress streams to stdout: the launches, each driver's log followed and prefixed `[<rung>
r<rep>]`, waits, outcomes, checks and a summary. The coordinator commits the results and the
g3_defects.tsv rows.

**Exit:** 0 when every planned launch succeeded (a capacity retry that succeeded counts). 1 when
a rung stopped or an item was not launched. 2 when it refused to start on a dirty tree. 3 on a
hard stop: orphans with nothing in flight, a Law 1 DEFECT, a check that cannot judge, or a signal.

**The stub test** (`scripts/tests/ladder_campaign_test.py`, in `make test`, about 30 s) runs the
real planner and driver in a scratch repo. The repo holds real committed c1 specs, the lever table
and a synthetic record. `make run`, `make orphans`, `make g3-ladder` and `quota_check.sh` are
stubs, through the `AK2_CAMPAIGN_*` seams:
- the run stub writes cohort dirs as run-multi.sh does. It exits 3, with a clean record, whenever
  another run is in flight, as run-multi's old global orphan check did;
- the tables stub writes `runs.tsv` and the summary line.

The cases:
- **plan:**
  - the ordering, rep 2 reversed, and the skip;
  - each reason a record run is not counted: failed, a recorded defect, params, spec sha256,
    prefix not fetched, excluded by the tables;
  - an old cohort's global `orphans_rc` 1 does not disqualify it;
  - DRY_RUN writes nothing in the repo.
- **skip:** the run skips the done item.
- **default:** CONCURRENCY=1 means never two runs in flight.
- **normal** (CONCURRENCY=4):
  - the first launch runs alone;
  - X reaches its limit of 2 and never exceeds it;
  - each rung's rep 2 starts after its rep 1 ends;
  - `AK2_LADDER_REP` reaches `params.rep`, and neither DRY_RUN nor MAKEFLAGS is passed on;
  - nothing launches while quota_check refuses;
  - orphans run before, after each run and at the end;
  - runs whose make run exited 3 only because of another run's instance are `ok`.
- **capacity:** x8g is retried in us-west-2c, and rep 2 runs in the spec's AZ. r8gd has no
  alternative, so the rung stops. Both rows reach g3_defects.tsv.
- **failure:** a failed run, a run in the wrong AZ, and a run the tables exclude each stop their
  rung; the other rung goes on.
- **orphans:** a finding is informational with a run in flight, and a hard stop with none.
- **law1:**
  - the campaign stops after a Law 1 DEFECT;
  - it refuses to start when one is already there;
  - a g3-ladder crash (exit 1, no summary line) is a hard stop, in the run and in DRY_RUN.

**Not covered locally:** real spawn launches, real capacity errors (matched by the string
`InsufficientInstanceCapacity`), and real quota numbers.

## Selection: `make ladder-select`

**What:** applies the registered `select` rules of `ladder.levers.tsv` at one cohort, from a fresh
run of make g3-ladder's program, and writes each winner as a row of `scripts/g3/ladder.resolved.tsv`.
Every selection is an alias over candidate rungs ("Candidate rungs", above).
It launches nothing and costs $0.

```bash
DRY_RUN=1 make ladder-select COHORT=1           # what it would write; nothing is written
make ladder-select COHORT=1                     # every rule; writes the ones it can select
make ladder-select COHORT=10 RUNG=Sstar-time    # one rule (or a list: RUNG=Sstar-time,Sstar-cost)
make ladder-select-test                         # its stub test (synthetic record; in make test)
```

`scripts/g3/ladder-select.sh` (`set +e`, logs `$-`) runs `scripts/lib/ladder_select.py`.

**The rules are read, not restated.** Each rule's candidates, axis (`axis: median wall_s`,
`axis: median billed_usd`, or `the #26 fit's time|cost-optimal N`) and ties (`ties: fewer …`) are
parsed from its text in the table. A rule without them is refused. Every row's note carries the
sha256 of the rule text.

**The tables.** `ladder_tables.py` runs on the whole record into a scratch dir, with the current
lever table and `ladder.resolved.tsv`. Its summary line must be there and there must be no
`DEFECT (Law 1)`, as the campaign judges it; otherwise nothing is selected. Other DEFECT classes
do not stop it. The c1 record now has three, all on the refused S2a launch: the successor-phase
check no longer counts rungs that are not run at the run's cohort. The medians come from its
`rungs.tsv`. The runs behind each median come from its `runs.tsv`: cold ladder runs at the cohort,
in the attribution. Their count must equal the median's n.

**What it selects: every alias rung** (S4, S8, Sstar-time, Sstar-cost, O2, O2-cost, O3, O3-cost),
in table order, so that a selection made in the same run (O2, say) reaches the rules after it
(O3's bracket).
- **The candidates** are the alias's `alias_of`, which must be exactly the rungs the rule's
  `candidates:` clause names: every one, and no other. A rung named in the possessive ("O2's
  family") is not a candidate. At the cohort, the set leaves out:
  - a candidate not run there, unless it is the alias's own predecessor, which stands for the
    configuration it has there (O1 at c1 is O0b's);
  - a candidate outside the rule's bracket (O3).

  Fewer than two candidates left is refused: that rung needs a `not_run_cohorts` entry, not a
  selection.
- **The median** of each candidate is read from the rung whose runs it has (`config_row`): its
  `alias_cohorts` target, a not-run predecessor's run ancestor, or an alias's winner. The note
  names it ("O2-r8g's runs").
- Every candidate needs n ≥ 2 measured runs at the cohort on the rule's axis; otherwise the rule is
  not selected.
- **The axis** is exactly the rule's: `wall_s` (gross) or `billed_usd` (gross). The net series is
  in the note beside it, for information. It does not decide.
- **The lowest median wins.** An exact tie on the median is broken by the rule's ties, from the
  candidate's resolved values: fewer vCPUs, processes, nodes, fleet vCPUs or in flight. A tie left
  after that is refused.
- **The margin** (runner-up − winner) is judged by the tables' own rule (`ladder_tables.delta`).
  It is resolved only if it is > 2 × max(the two ranges, q); otherwise it is `unresolvable:
  <reason>`. The winner is still the registered rule's winner, and the `margin` column then says
  `…: chosen by the registered rule from an unresolvable difference`.

**What it reports and does not write:**
- **A rung not run at the cohort** (`not_run_cohorts`: at c1, S4, S8, O4b and O4b-cost). Its
  tokens already resolve to its run predecessor's values, so a row would be ignored.
- **A selecting rung without candidate rungs** (O4b and O4b-cost above c1).
- **An alias that cannot be selected yet:**
  - a candidate with n < 2;
  - a candidate still unresolved (O3 before O2);
  - an unbroken tie.

**`RUNG=` is all or nothing:** with it, any of these is a refusal (exit 3), and nothing is written.
Without it they are listed as `not selected: …`, and every rule that did select is written. At c1
on the current record, the S\* rows stand. O2 and O2-cost wait for O2-r8g's runs, and O3 and
O3-cost wait for O2.

**A row:**
- `origin`, `cohort`, `key` (`alias`), `value` (the winner).
- `source`: the tables' `manifest.json` in the selection's snapshot,
  `results/g3/ladder-select/c<C>-<fp>/`. The snapshot is a full copy of the tables it used, so
  `source_ok` accepts it as a dir holding a manifest.
- `cites`: `path=sha256` of each of these:
  - the snapshot's `manifest.json`, `rungs.tsv` and `runs.tsv`;
  - each measured candidate run's `cohort.json` and member `manifest.json`, or a single run's
    `manifest.json`;
  - for a bracketed rule, the fit's `predictions.tsv`.

  `ladder_levers.py` checks every cite (`cites_ok`). A cited file that changes later makes the
  generator refuse the row. `ladder_tables.py` checks them too (`cite_problem`): a row whose cites
  do not verify leaves the alias "alias unresolved" there, with a note in summary.md and
  manifest.json.
- `margin` (above).
- `note`, in this order:
  - `rule sha256 <hex>`: the generator refuses the row once the rule text changes;
  - each candidate's median, n, range, q, host and vCPUs, its tie quantity, and the rung whose runs
    it reads;
  - the winner and runner-up, the margin and its threshold, and the net-series order;
  - the bracket, and the candidates left out.

**Deterministic and idempotent.** A row stands, byte for byte, when both of these hold:
- its winner, margin, note and cited runs (with their sha256) are what this run derives;
- its source and cites still check.

Only changed rows are written, and no snapshot is made otherwise. Rows for other rungs and cohorts
are kept as they are.
- The snapshot dir is named by the sha256 of the changed rows' decisions, so the same record gives
  the same name.
- Its `manifest.json` carries the tables' `generated_at`. So two snapshots made from scratch differ
  only in that file's sha256.
- The file is written whole and read back through `ladder_levers.read_resolved` and
  `ladder_tables.load_resolved`. If either fails, the file is restored.

**Commit before the next launch.** The file is under `scripts/g3/`, and run.sh refuses a dirty
tree. The target prints that the coordinator must commit `ladder.resolved.tsv` and the snapshot
dir before any launch.

**Exit:**
- 0: written or unchanged. The rules not selected are listed.
- 2: usage.
- 3: refused, with nothing written. The refusals are:
  - a lever table that fails make ladder-check;
  - a g3-ladder run with no summary line, or with a Law 1 DEFECT;
  - a current `ladder.resolved.tsv` whose citations fail, or whose rule sha256 no longer matches;
  - with `RUNG=`, a rule it could not select.

**The stub test** (`scripts/tests/ladder_select_test.py`) builds scratch roots holding the real
lever table and a synthetic record. The records are made with `ladder_tables_test.py`'s helpers
(Law 3: unit test only), and the test runs the real `ladder_tables.py` on them. The cases:
- **resolved:** S\*-time goes to S9 by 100 s against a 4 s threshold. S\*-cost goes to Sstar-r8gd,
  with billed set by hand against the time order.
- **unresolvable:** S9 wins by 2 s against 4 s, and is labelled.
- **tie:** S9 wins by fewer vCPUs (96 < 192), with margin 0, unresolvable.
- **citations:**
  - the cites pass `ladder_levers`, and the tables read the rows;
  - O0's host is the winner's;
  - a tampered cited manifest fails the check, and ladder-select then refuses;
  - the tables leave the alias unresolved, with the note;
  - a changed rule text is refused by `ladder_levers` and by ladder-select.
- **idempotence:**
  - a second run changes nothing;
  - a new run replaces the row, with a new snapshot;
  - DRY_RUN writes nothing, and `RUNG=` touches only its own row.
- **refusals:**
  - n = 1, which is listed without `RUNG=` and refused with it;
  - a Law 1 DEFECT;
  - g3-ladder without its summary line (a planted crash, through the `AK2_SELECT_TABLES` seam);
  - `RUNG=O2` with no candidate runs.

  S4 and O4b at c1 are not run there (exit 0).
- **parsing:** every registered rule parses. A rule without an axis is refused, and so is one with
  two axis clauses or two ties clauses.
- **candidate rungs:**
  - S4 at c10 over S2a and the five S4-t\<T\> with P ≤ 10: S4-t24 wins, resolved, and S5 then
    takes THREADS=24, PROCS=vcpus/24;
  - O2 and O2-cost at c1 over O1 (O0b's runs) and O2-r8g, with O2-cost-r8g reading O2-r8g's runs:
    time picks O2-r8g, billed $ picks O1-cost;
  - O3 is listed, with no candidate runs, and O3-n2 is generated on O2's winner's type;
  - the tables read O2-cost as O0b's runs.

`scripts/tests/ladder_levers_tables_test.py` (the tables cross-check) runs a synthetic record of
every rung run at c1 through the real lever table. It resolves the aliases (S\* to Sstar-r8g, O2 to
O2-r8g, O3 to O3-n4, and their -cost copies), and a copy of the table declares the cost chain's
coincidence through O5-cost in `alias_cohorts`. `alias_cohort_problems` confirms each declaration.
Both S\* vs O\* pairs must then have 6 resolved lever rows that sum to their totals (O0, O0b, O2,
O3, O4a and O5; O1 and O4b are not run at c1). The cost pair's rows must read the time chain's
runs.

## The rehearsal (#53): `make rehearse-ladder`

**What:** the ladder body end to end before any rung launches on AWS, on every arm, checked on
observed output only. Each check has been shown to fail under a planted defect (a negative
control). It launches nothing and costs $0.

```bash
make rehearse-ladder                                   # everything below; after make util-stream-test
make rehearse SPEC=runs/g3-l-s5-c1.json                # one committed c1 spec (after util-stream-test)
LADREH_RECORD=DIR make rehearse SPEC=runs/g3-l-s5-c1.json   # ...and keep its run record in DIR
scripts/lib/ladder_rehearse.sh tables DIR              # make g3-ladder's program on that record
scripts/lib/ladder_rehearse.sh only arms s5            # development: some groups (arms s5 law1 neg net resolver ttl specs)
```

Record: `results/rehearse/ladder-<UTC>-<sha7>.log` (one spec: `ladder-<rung>-<UTC>-<sha7>.log`),
ending in a summary table, one row per case. `make rehearse-ladder` also keeps the tables it
made from the rehearsal record in `results/rehearse/ladder-<UTC>-<sha7>-tables/`. `KEEP=1` keeps
the scratch dir. The tree must be committed: the nodes clone HEAD.

**The nodes.** Each node is an Amazon Linux 2023 aarch64 container, running exactly what run.sh
launches: `scripts/preamble.sh` followed by the body, as `bash -e -c` (spawn's `$-` has `e`). The
rehearsal adds one line between them, which logs pipefail's state. The node runs as ec2-user with
sudo, on rootful podman with `--privileged`. That gives it the VM's real `drop_caches`, real
tmpfs mounts with `huge=`, and the real THP knobs. The members of a cohort are containers on one
podman network, so the engine's shards connect over TCP to each other's addresses. The home dir,
`/tmp` and the NVMe stand-in are tmpfs, so nothing is written to the VM's disk.

The committed tree is cloned from a git bundle of HEAD and built on the node:
- upstream at the pin by `scripts/oracle-build.sh`, from a clone of the shared upstream checkout;
- ours by `make build` (Go in the image, the host's module cache).

`scripts/lib/ladder_rehearse_check.py` makes the checks; the driver is `scripts/lib/ladder_rehearse.sh`.

**Stand-ins, only at the edges:**
- **RODA is the viral database** (`k2_viral_20260626`, real), with a real 16 MiB-part multipart
  ETag. The engine's ranged GETs go to `k2probe serve-file` (Range, If-Match) on an infra
  container. Standard-8 cannot be used: its hash.k2d is 8.0 GB and the podman VM has 8 GiB, so
  neither a resident table (upstream without `-M`, the engine) nor two shards of it fit.
- **S3 is one directory on the host.** `aws` and `s5cmd` are stubs over it, and every call is
  logged. Uploads under a cohort's `out/` can be made slow (`AK2T_UP_SLEEP`), so overlap is
  visible. The engine's SDK talks to `k2probe fakes3` over the same directory. The staged
  cohort objects carry `Metadata.sha256`.
- `curl` answers IMDS (the spec's instance type, the container's own address) and the
  bucket-region HEAD. `sudo` answers `dnf install` with `rpm -q`, since the image has the
  packages.
- **The samples are real public read sets** (200,000 pairs from `.cache/reads`), named by their
  run accessions through the body's `AK2_REHEARSE_SAMPLES`/`WEIGHTS` seam. `rapidgzip` is the
  real 0.14.5 wheel, installed by lever.sh with `pip --require-hashes` (`AK2_REHEARSE_WHEELS`).
- **The oracle** is upstream at the pin (`scripts/oracle-build.sh`, the `make oracle` build), run
  on the host on the same reads uncompressed. A precondition checks that each `.fq.gz`
  decompresses to its `.fq`.

**What every passing case checks** (per node, on the pushed `log/run.log` and `out/`, the
container's stdout and the bucket):
- **Exits and shell:** the body exits 0, under `bash -e -c` and the preamble's `set +e`.
- **Streaming:**
  - the `lad-sample` lines streamed equal `out/lad-samples.jsonl` and the container's own stdout;
  - one `lad-net` line, streamed and pushed;
  - the `lever` lines equal `out/lever.jsonl`.
- **Samples:** every planned sample has exactly one line across the fleet, with rc 0 and contract v1.
- **Law 1:** every output's and report's on-node sha256 equals the oracle's, and the uploaded
  object's sha256 equals the recorded one. There are 2 objects per sample.
- **Phases:** every phase is present, in the body's order for the arm. The cold markers are
  exactly `setup` and `load`, and the log shows 2 `drop_caches`.
- **lad-net:**
  - `critical_measurement_s` = identity + sha_get + sha_critical;
  - `sha_critical_s` = the sum of the samples' `sha-critical`;
  - `identity_s` and `sha_get_s` equal their phases (within the whole-second markers).
- **Requests:**
  - PutObject + CompleteMultipartUpload − Rendezvous-PutObject = the objects;
  - fetch.sh's HeadObject = the input files;
  - the database staging is counted (a ranged load on the engine).
- **Build:** under SETUP=serial the build is waited for in setup. Under overlap it is waited for
  in build-wait, with `build_end` recorded before identity (or load).
- **Engine:**
  - the `ak2-engine etag` line has etag = computed;
  - each replica has its own rendezvous;
  - the shard addresses are the nodes' own;
  - at N > 1, every shard homes samples.
- **Plain** (ours-plain only): nothing is written under the cohort's `rendezvous/` prefix, and
  Rendezvous-PutObject is 0. The containers carry the node's real cohort env
  (`AK2_ENGINE_N`/`RANK`/`RENDEZVOUS`, as make run sets it). If that env leaked into ours' plain
  path, ours would run the engine and rendezvous there. That leak is what O0 at c1 hit at
  843e958, and the earlier rehearsals passed it: on the viral DB the outputs are identical and the
  extra copy is small. The `specs` group's `spec-o0-engenvmut` plants the leak back (`mut_engenv`)
  and must fail this check.
- **S5:**
  - one identity line per input, at the run's -P;
  - `input_defect` as expected;
  - `s5` status and fallback per sample;
  - `gzip-shim.calls` has 2 rapidgzip calls per non-fallback sample, and `s5-fallback.calls` 2
    GNU gzip calls per fallback sample.

**Cases** (the record's summary table names each):

| item | cases | what |
|---|---|---|
| 1 | `u-serial-1lane`, `u-overlap-1lane`, `u-serial-2lanes`, `u-overlap-2lanes` | upstream per-sample: s5cmd-serial and s5cmd-overlap, awscp-default (stock) on NVMe with load, 1 and 2 lanes; serial blocks the lane, overlap does not (uploads take 2 s), the lanes run at once |
| 1 | `ours-plain` | ours' plain path under rapidgzip (`AK2_DECOMPRESS=pipe`) |
| 1 | `engine-k2`, `engine-n2`, `o5-sdk` | the engine at K = 2 replicas, at N = 2 shards (lpt) over TCP, and O5's sdk-stream emitter at N = 2, with sha256 by GET |
| 1 | `law1-across-arms` | each sample's sha256 is one value across every passing arm, the oracle's |
| 2 | `s5-trailing` | real rapidgzip on SRR28305653 with 4096 zero bytes after mate 1 (the oracle's zeropad variant). Only that sample differs and falls back. The recorded exits and sha256 equal an independent run of the same tools at the same -P |
| 2 | `s5-garbage` | ERR478965 with a garbage line after mate 1 (the oracle's garbage variant). GNU gzip exits 2, its warning, so the input is kept: `gz_warning`, no `input_defect`. rapidgzip differs, so the sample falls back, and Law 1 holds. The recorded exits equal an independent run |
| 2 | `s5-corrupt` | mate 1 cut at half its bytes. `input_defect` is set on that file only, with GNU gzip's real exit, and the run fails (the classifier sees a short mate) |
| 3 | `neg-*` | each fails the run, for its stated reason (the message is checked): a gzip, and a bzip2, in KRAKEN2_DIR (the upstream build mutated); an ETag mismatch via lv_etag and via the engine; a classifier exiting non-zero (a truncated mate; its rc is in the lad-sample line); an engine home sample with no ak2-sample line; `cohort_place.py needs` failing, `table` failing, the two disagreeing, and an empty NEED that the table agrees with |
| 4 | `overlap-slow-build` | SETUP=overlap with a build 20 s slower: build-wait, identity, load, and the wait observed |
| 4 | `tail-crit-*` | 3 lanes over 3 identical 1M-pair samples end together and uploads take 4 s. At least 2 output hashes fall after the last classify span (check `tail-resolve`; otherwise it is run again, up to 3 times, and the unresolved try is a RETRY row). sha_critical is about one hash, not the tail's sum |
| 5 | `resolver` | the generator's resolver refuses a resolution with no citation, one identical by value to its predecessor, and an alias winner outside alias_of. A one-lever resolution is accepted (positive control). S4 and S8 are not run at c1, and S5 and S9 take S2a's and S7b's values. A c1 row for S4 is ignored with a warning. The committed specs' parameter blocks are the resolver's |
| 6 | `spec-<rung>` × 15 | every committed `runs/g3-l-*-c1.json`, its body being the committed body plus its parameter block |
| 6 | `tables`, `tables-lever-phase` | `ladder_tables.py` on their record, with a rehearsal-only `ladder.resolved.tsv` (Sstar-time → S9, Sstar-cost → Sstar-r8gd) in the record dir, never in `scripts/g3/`. It must give 15 runs and 0 DEFECTs, law1.tsv all identical, and each alias's rows equal to its winner's on an axis where the three candidates differ. Every rung's lever phase must be measured |
| 7 | `ttl-kill`, `ttl-term` | the node killed while the second sample (8M pairs) classifies. KILL: every line streamed 7 s before is in the pushed log, from the 5 s pusher. TERM: every line up to the kill is there, and the finish ran |

**Negative controls** (each case passes only if its named check fails):

| case | planted defect | check that must fail |
|---|---|---|
| `law1-mut` | the classifier called with `--minimum-hit-groups 3` | law1 |
| `s5-mut-nofallback` | no sample marked as differing (the fallback never installs) | s5 and law1 |
| `s5-mut-net` | identity left out of lad-net's sum | net |
| `tail-mut-*` | lad_crit without NB1 (uploads do not cover a hash) | tail, with `tail-resolve` passing on the same run (the probe resolved) |
| `ttl-kill-nopush` | the preamble's 5 s pusher removed | the kill check |
| `spec-s1-law1mut`, `tables-neg` | an S1 run with the Law 1 mutation added to a copy of the record; an alias winner outside alias_of | Law 1 DEFECT; DEFECT (resolved) |

**Failure looks like:** a `FAIL <case>: <check>: …` line, the tail of each node's output, and
`FAIL` in that case's summary row. Exit 1.

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
make g3-ladder        # every ladder run under results/*/<yyyymmdd>-*; OUT=DIR writes elsewhere; then read results/g3/ladder/summary.md
python3 scripts/lib/ladder_tables.py --results DIR --levers FILE --modelled FILE --resolved FILE --out DIR
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
| `s5` | yes | object | `{"status": "n/a"\|"identical"\|"differs", "fallback": "none"\|"gzip", "gz_sha256": [hex, ...], "rg_sha256": [hex, ...], "gz_exit": [int, ...], "gz_warning": [bool, ...], "rg_exit": [int, ...], "P": int, "nproc": int}`. `n/a` means the run does not use rapidgzip; the lists are then not read. Otherwise `status` is the identity phase's result for this input, and `gz_sha256` and `rg_sha256` are the sha256 of gzip's and of rapidgzip's decompressed output, with `gz_exit` and `rg_exit` each tool's real exit status, one per input file in mate order (R1, R2). The four lists must have the same length: the shas 64 lowercase hex, the exits integers. **The body's B1 rule** decides `differs`: the sha lists differ, **or** any `rg_exit` is non-zero, **or** any `gz_exit` is other than 0 or 2, **or** either list holds the empty-stream sha256 (`e3b0c442…b855`). `differs` must satisfy it and `identical` must not; so `identical` with a non-zero rapidgzip exit, a gzip exit other than 0 or 2, or an empty output, is a contract DEFECT. GNU gzip's exit 2 is its warning (output complete; upstream's wrapper ignores it): `gz_warning`, when present, must be `gz_exit == 2` per mate, or it is a contract DEFECT. **A `gz_exit` other than 0 or 2, or an empty gzip stream** (`e3b0c442…` in `gz_sha256`), is a DEFECT of its own, of class `input`: an input or staging failure, not an S5 finding. The same DEFECT is raised from the body's **identity line** (`lad-identity {json}`, kind `identity`, in `out/lad.jsonl`) when it carries `input_defect: true`, for an input whose sample's `s5` does not already show it. A sample flagged both ways gets one DEFECT. The run is excluded, and the sample is not counted in the S5 fallback finding. `fallback` defaults to `none`. When `status` is `differs`, the body must decompress that sample with gzip instead and record `"fallback": "gzip"`. `differs` with `fallback: none` is a contract DEFECT, and so is `fallback: gzip` with any other status. |
| `rank`, `idx`, `input_bytes`, `threads` | no | | node rank, index in the cohort, input bytes, threads |

A missing or ill-typed required field is a DEFECT (contract) and excludes the run.

**`lad-net` line, one per node** (Scott's gross/net ruling, 2026-10-10; #51 computes the number
under its rule). Each node emits `lad-net {json}` in its run log (streamed) and writes the same
object as the one line of `out/lad-net.jsonl` (pushed; any depth under `out/`). This covers every
rung, with 0 where the node did no measurement-only work:

| field | required | type | meaning |
|---|---|---|---|
| `v` | yes | int | exactly `1` |
| `rank` | yes | int | the node's rank (0 for a single run; the cohort.json member rank otherwise) |
| `critical_measurement_s` | yes | number ≥ 0 | the node's measurement-only seconds on its critical path, 3 decimals: everything #51's rule takes out of the gross wall (S5's identity, O5's sha-get, the critical share of output hashing, …) |
| `identity_s`, `sha_get_s`, `sha_critical_s` | no (all or none) | numbers ≥ 0 | #51's components of `critical_measurement_s`: S5's identity phase, O5's sha-get, and the sum of the node's samples' `sha-critical`. If any is given, all three must be, and they must sum to `critical_measurement_s` within 1 ms; otherwise it is a DEFECT (contract). runs.tsv shows them as `net_components`. |

A missing line makes the run's net missing, with a note. The following are each a DEFECT
(contract), and the run is excluded:
- a malformed line: a wrong `v`, a rank that is not the node's, or negative seconds;
- more than one line per node;
- a `critical_measurement_s` larger than the node's own window (`terminated_at` − `launch_time`).

With that last rule, net can never be negative.

**`scripts/g3/ladder.levers.tsv`** (#51) is tab-separated with a header row. `#` lines are
comments. Columns are read by name:

| column | meaning |
|---|---|
| `rung`, `arm` | the rung and its arm |
| `predecessor` | the rung this one changes one lever from (empty or `-` for a root) |
| `lever` | the lever key-group. `stock` marks only the root S0-T1. S0-Tv's predecessor is S0-T1 and its lever is `threads`. S5's lever is `rapidgzip`, which is how the S5 findings find it. |
| `counterpart` | the O counterpart of an S lever, or the stated reason there is none |
| `phase` | the lever's own phase. `run:NAME` is a manifest phase; `sample:NAME` is the sum over the run's lad-sample `phases.NAME`; a bare `NAME` means run if the manifest has it, else sample. `A+B` sums the two, each term with its own scope (`run:fetch-db+run:load+run:classify`, as this table writes a compound phase; `sample:A+run:B` alike). A term of a run's own lever phase that matches nothing (no such manifest phase, no lad-sample with it) is a DEFECT (contract), and the run is excluded. A run successor's phase term that the predecessor run lacks is a DEFECT (contract) too if the body marks that phase on every run (setup, fetch-db, etag-hash.k2d, fetch-inputs, load, classify, upload-drain), and a note if it is a conditional one (identity, build-wait, sha-get), which the successor's lever may be what adds. |
| `endpoint` | the endpoint(s) this rung is, for example `S*-time;S*-cost` (every cohort) or `c1:S*-time;c10:S*-time` (per cohort; a per-cohort declaration wins). Two rungs declaring the same endpoint for the same cohort is a DEFECT (levers). An endpoint that is not declared gives the status "endpoint not declared"; nothing is selected from the data. |
| `pred_wall_s`, `pred_usd`, `pred_phase_s` (optional) | the predicted delta on each axis, set against the threshold |
| `alias_of` | for an alias rung, its candidates separated by `\|` (e.g. `S9\|Sstar-r8g\|Sstar-r8gd`) |
| `status` (optional) | empty or `run` for a run rung. `alias: <rule>`, with `alias_of` set, marks an **alias rung** (Sstar-time, Sstar-cost): it has no runs of its own, and at each cohort its runs are those of the winner that `scripts/g3/ladder.resolved.tsv` names for it (below). An alias with no resolution at a cohort, or whose named winner is not one of its `alias_of`, gives the status "alias unresolved" in rungs.tsv, deltas.tsv and pairs.tsv, never a silent empty. A ladder.resolved.tsv row whose winner is outside `alias_of`, and a second row for the same (rung, cohort), are each a DEFECT (resolved) and leave the alias unresolved there. An alias left unresolved at a cohort where any of its candidates has runs gets a note. An alias whose winner is its own predecessor adds no lever: its delta row says "<rung> is an alias of its predecessor <rung>: no lever", and the pairs skip it. Otherwise the alias's delta is its winner's runs against the alias's predecessor, labelled "alias of <winner>". A rung that takes an alias as its predecessor (O0) is measured against the winner's runs. |
| `status`, continued | `not-run: <reason>` (read from this column only) means the rung is not run, for example `not-run: no parameter change` for S3 when the tune probe chose `none`. It has its own deltas row labelled with that text and no numbers. Its successor's delta is taken against the **nearest run ancestor**, and labelled with that ancestor and with the skipped rung's text (deltas.tsv `predecessor_basis` and status; pairs.tsv lever-row note). The pairs skip the rung. A run on such a rung gets a note. |
| `not_run_cohorts` (optional) | the cohorts at which the rung is not run, as `c1: <reason>;c10: <reason>` (#51's form) or a bare `1;10`. At a listed cohort the rung is treated exactly as `status: not-run`: its own deltas row carries "not-run at c<k>: <reason> (not_run_cohorts)", the pairs skip it, and its successor's delta is against the nearest ancestor that ran there. At other cohorts it is an ordinary rung. (S4 and S8 at c1, where their only candidate is the predecessor's configuration.) |
| `alias_cohorts` (optional) | `c1: O0;...`: at those cohorts the rung has the named rung's configuration (the cost chain where it coincides with the time chain) and reads its runs: rungs.tsv basis "alias: same configuration as O0 at c1 (alias_cohorts)", its delta against its own predecessor, skipped in the pairs when the two read the same runs. A run of the rung itself there is not used (a note). The generator checks that the two resolve to one configuration ("The cost chain reads the time chain", above). |

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
- billed(c100) = wall × price/h × nodes / 3600;
- net, from the run's net wall (the per-node lad-net rule):
  - C = wall − net wall is the run's measurement-only seconds;
  - its in-sample share C_in, the sum of the samples' own `phases["sha-critical"]` and
    `phases["s5-identity"]` (inside their spans), scales with the samples, and the rest is fixed;
  - wall_net(c100) = (net wall − S + C_in) + (S − C_in) × P_target / P;
  - billed_net(c100) = billed(c100) × wall_net/wall, prorated as the tables prorate.

  A run whose sample lines carry neither share is labelled "measurement treated as fixed at its
  c10 value" in `basis`; its formula reduces to F_net + P_target / r. The `wall_net_s` and
  `billed_net_usd` rows are written only when every run used has a net wall, C_in ≤ C and a
  fixed part ≥ 0. Otherwise the message names the run, and only the gross rows are written.

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

**`scripts/g3/ladder.resolved.tsv`** (#51; `--resolved`) is tab-separated with the columns
`origin`, `cohort`, `key`, `value` and `source` (and `cites`, `margin` and `note`: "Selection"). The tables read only the rows with key `alias`:
`origin` is the alias rung, `cohort` is a number (`c10` is also read), and `value` is the winning
rung. The file is cited in manifest.json when it exists.

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
- **Gross and net** (Scott, 2026-10-10, #25): every wall delta and pair is reported both ways,
  with **net as the headline**. The tables do not re-derive the measurement-only work. Under
  SETUP=overlap the identity phase includes the build wait, and sha-critical is only approximate,
  so #51 defines the final rule and gives each node's number in its **`lad-net`** line (below).
  The rule here, an interim one, is computed per node:

  **net wall = max over nodes of (that node's `terminated_at` − its `critical_measurement_s`) −
  the first `launch_time`.**

  For a single node, this is wall − critical_measurement_s. If any node lacks a valid lad-net
  line or its timestamps, net is missing (not imputed) and a note says so; gross stays in the
  attribution. **Net billed and net effective cost** are prorated, billed × net/gross, and labelled
  "net (prorated)". Net wall's granularity is 2 s for the timestamps plus 1 ms for the measured
  seconds. The axes are `wall_net_s`/`wall_s`, `billed_net_usd`/`billed_usd` and
  `eff_*_net_usd`/`eff_*_usd`. The `series` column labels each axis "net (headline)",
  "net (prorated; headline)", "net (prorated)" or "gross", and `net_basis` names the rule. The
  resolution check runs on each series separately. A `critical_measurement_s` beyond its node's
  window is a contract DEFECT, so net is never negative. The modelled
  rows (`make g3-ladder-model`) carry both gross and net.
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
| `runs.tsv` | one row per ladder run: PARAMS, type, nodes, commit, price, wall_s and wall_net_s with critical_measurement_s per rank (`r0=…;r1=…`) and net_basis, billed_usd and billed_net_usd, each effective cost gross and net, lever phase, planned and emitted samples, U_* (cpu, mem mean and peak, net baseline/peak and each direction), util cost_usd, each effective cost, util coverage, whether it is in the attribution (with the reason if not), notes |
| `tidy.tsv` | long rows: run-level metrics plus every lad-sample field (pairs, rc, phase.*, output.<role>.bytes and .sha256, s5.status, s5.fallback, and s5.gz_warning: the mates on which GNU gzip exited 2, or none). summary.md has a `gz_warning:` note for each such sample |
| `rungs.tsv` | per (arm, rung, cohort) and axis (wall_s, billed_usd, lever_phase_s): basis (measured or modelled), n, median, min, max, range, granularity_q |
| `deltas.tsv` | each rung against its predecessor (or its nearest run ancestor, or an alias's winner: `predecessor_basis`) on wall net and gross, billed net and gross, and the lever phase (`series`, `net_basis`): ranges, measured spread, q, threshold, status, predicted delta and whether it was resolvable; a `not-run` rung's row carries its label |
| `effcost.tsv` | per (arm, rung, cohort): median and range of each U and each effective cost, with q, util coverage, and any missing util named |
| `pairs.tsv` | the three pairs × cohort × axis, net and gross (`series`): lever rows, then the total row (sum of lever deltas, residual, ratio, endpoint basis, util coverage, net basis) |
| `law1.tsv`, `law1-detail.tsv` | per accession, and per accession × run × role: the sha256 against what it was compared with, and the status |
| `s5-nonpreserving.tsv` | every `differs` entry (both arms): fallback, P, nproc, `rg_sha256`, whether its outputs equal the reference, its Law 1 status, and the S5 check (S rapidgzip output, disagreement flag, or the O-arm match) |
| `endpoints.tsv` | the endpoint runs: per (arm, endpoint, rung, cohort, state = cold, warm or cold-local), with wall, billed and each manifest phase (n, median, range) |
| `spend.tsv` | every ladder run's billed $, whether `results/g3/campaign/spend.tsv` has it, and the total |
| `summary.md` | counts, exclusions, DEFECTs, findings against levers, notes, and each pair total (with the endpoint basis) followed by its per-lever rows (rung, delta, status). Generated, and cites only the tables. |
| `manifest.json` | the generator, its commit and dirty flag, every input with its bytes and sha256 (only ladder runs' files, the lever, modelled and resolved tables, and any runs.tsv used), every output's sha256, the runs with their PARAMS, DEFECTs, findings and notes |

**Spend.** `g3_campaign.py` (`make g3-tables`) already counts ladder runs under `results/g3/`:
single runs, and cohorts through their members' manifests. It also counts ladder dirs under any
other gate, recognised by a `params` entry that names a rung. In this target's `spend.tsv`, any
ladder run missing from the campaign total is marked `NO`, and a note is added.

**Failure looks like:** `ladder_tables: DEFECT (<class>): …` on stderr, with exit 1. The classes
are `Law 1`, `contract`, `incomplete`, `sample failed` and `levers`. For a Law 1 DEFECT,
law1-detail.tsv has both sha256 values. runs.tsv's `in_attribution` gives the reason for each
excluded run.
