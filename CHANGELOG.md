# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `make g3-ladder` (`scripts/lib/ladder_tables.py`; #52, WP-8 of the #25 ladder). It builds the
  ladder's tables from the record only and writes them to `results/g3/ladder/`:
  - per-run tidy rows from the `lad-sample` lines plus the manifest, with billed $, U_cpu,
    U_mem and U_net from the fleet row of `tables/util.tsv`. A missing row is reported as
    missing, never imputed.
  - per-rung, per-cohort medians and ranges on wall, billed $ and the lever's own phase. Runs
    with any DEFECT are excluded: incomplete against the planned accession set (a cohort's
    comes from cohort.json), a cohort member that never launched, a failed sample, a contract
    error, or a Law 1 DEFECT.
  - each rung's delta against its predecessor, or against its nearest run ancestor when a rung
    is marked `not-run` (labelled so). A delta is resolved only if |Δmedian| > 2 × max(range,
    range, instrument granularity q). Otherwise it is unresolvable, never a null, with "below
    instrument granularity" as its own label. The predicted delta and the measured spread are
    shown beside it.
  - effective cost per resource (util's fleet cost_usd ÷ U_cpu, ÷ U_mem, ÷ U_net, and U_net per
    direction), never combined.
  - the three pairs S vs S\*, S vs O\* and S\* vs O\* on the declared (per-cohort) time and cost
    endpoints. Each total sits beside its per-lever decomposition, in pairs.tsv and summary.md.
  - cross-arm Law 1 against a stock reference, by on-node sha256 and file set. Any mismatch,
    and any O-arm accession without a stock reference, is a DEFECT, and the target exits 1.
    S5: a failed identity check falls back to gzip, which is reported as a finding against the
    lever. Without the fallback, the sample is a contract DEFECT. rapidgzip's output sha256
    (`rg_sha256`) matches O-arm entries to S entries and flags S entries that disagree.
  - modelled values: `make g3-ladder-model` (`scripts/lib/ladder_model.py`) derives c100 stock
    T1 from the c10 S0-T1 records' per-thread rate. The per-sample span is the union of the
    lad-sample `t_start`/`t_end` intervals. A run with any DEFECT (Law 1 included) cannot feed
    the model, and F < 0 refuses it. Every file is cited with its sha256. g3-ladder re-derives
    every modelled row on the current record and refuses one whose files, runs or value do not
    match, then flags every use.
  - cold and warm endpoint rows; spend; and a `manifest.json` that cites every input with its
    sha256 and the commit.

  The `lad-sample`, PARAMS and lever-table contract with the ladder body (#51) is in
  docs/ladder.md, "Ladder tables". `make test` runs `scripts/lib/ladder_tables_test.py` on a
  synthetic record worked by hand. `g3_campaign.py` now also counts ladder run dirs under gates
  other than g3 in `spend.tsv`.
- `make g3-fit` (`scripts/lib/fit26.py`; #26, WP-10 of the #25 ladder). It fits the registered
  T(N) and cost model to the nine cohort-100 campaign points, from the record only, and writes
  `results/g3/fit26/`:
  - the registered form exactly as registered, end to end and per term;
  - then each addition as a separate fit: t_input, t_emit, t_net, t_fetch, t_sync, c_used and
    B_nic;
  - then every addition together, per term.

  For each fit it gives parameters with standard errors, residuals per point, leave-one-out
  refits, a designated held-out point (E4 N=32) and a cohort-size check of the classify term. It
  also gives the predicted time-optimal and cost-optimal N per cohort size (1, 10, 100, 1000) and
  family, with draw-based ranges and extrapolation flags (per regressor, and joint by leverage).
  It reports the registered cost formula's per-point residuals against derived and billed $
  (`cost_residuals.tsv`), and H-width's cost knee N* = (S/B + W/(c·r)) / (t_boot + t_tail) per
  type and cohort (`hwidth_knee.tsv`). Held-out z uses the prediction interval
  sqrt(se_param² + s²). Every point is marked pre-fix (#44), and so is every table.
  `manifest.json` lists every input with its sha256 and the commit. Stdlib only. `make test`
  runs `scripts/lib/fit26_test.py`, which tests the fitting code on synthetic data with known
  parameters. The runbook is in docs/cohort.md, "make g3-fit".
- `AK2_DECOMPRESS=pipe` (#48), ours' counterpart to upstream's ladder lever S5. With it, ours
  reads compressed input from `gzip -dc FILE` / `bzip2 -dc FILE` found on `PATH`, as upstream's
  `scripts/kraken2` wrapper does (`seqio.OpenPipe`). There is one child per input file, including
  each mate. Its exit status is ignored, its stderr is the run's, and it shares standard input.
  The in-process klauspost path stays the default. Any other value exits 64.
  - `make decomp-shim TOOL=gnu|pigz|rapidgzip DIR=…` (`scripts/decomp-shim.sh`) writes a `gzip`
    shim for `DECOMP_BIN`. It runs the tool for `gzip -dc FILE` and GNU gzip for everything else.
  - `make oracle` adds variants and cases for a truncated `.gz`, a garbage tail, a plain mate 2
    behind a gzip mate 1, and `--gzip-compressed` on a missing file and on a plain one. It also
    adds coverage checks, including one showing which decompressor ours used. An expected exit
    may list alternatives (`0,65`).
  - `make oracle`, `oracle-engine`, `oracle-cohort` and `equiv-seqout` record `AK2_DECOMPRESS`
    and the gzip on `PATH` in their manifests. `oracle-cohort` takes `DECOMP_BIN`, and the
    equiv-seqout Go tests read through `OpenPipe` under pipe mode.
  - The shared `.cache/equiv-seqout/latest` moves only for a PASS with the default decompressor.
    Each work directory records `decompressor` and `result`. `TestOracleSeqout` and
    `TestOracleDecompress` fail loudly on any other `latest`, or when `AK2_DECOMPRESS` is set in a
    plain `go test`. `make test` unsets `AK2_DECOMPRESS`.
  - `make oracle`, `oracle-cohort` and `equiv-seqout` fail if a `gzip` or `bzip2` sits in the
    upstream install directory, which the wrapper puts first on `PATH`. Shims go on `PATH`.
  - `make oracle` adds a zero-padding case (`se-zeropad-gz`) and a positive marker for pipe mode:
    every decompressor line in upstream's stderr also appears in ours. equiv-seqout's zero-padding
    and garbage cases accept exit `0,65`.
  - rapidgzip 0.14.5's loss on padded and garbage-tailed members varies with `-P`
    (`results/g1/rapidgzip-tail-loss-20261009T210618Z/`).
- `AK2_ENGINE_VERIFY_ETAG=1` (#49): the engine checks the S3 ETag of hash.k2d
  (`AK2_ENGINE_HASH_ETAG`) against the bytes its shards loaded, before the first sample. The part
  size is inferred as `scripts/lib/etagcheck.py` does (RODA v205: 8860 parts of 128 MiB), or
  given by `AK2_ENGINE_ETAG_PART_BYTES`. Single-part ETags are the plain md5.
  - **Guarantee:** every byte any node holds in memory, and every header a node parsed, is
    covered. Each is one of the bytes the ETag was recomputed from, or md5-equal to a copy of
    them. No byte is counted twice.
  - **Parts:** each node hashes the parts that start in its byte range, by file offset. It
    fetches the rest of its last part with one extra ranged GET.
  - **Cross-checks:** with no GET, the holder and the user of every overlap publish digests of
    their copies, which must be equal. An overlap is where a node's cells meet bytes another node
    used for the ETag: a straddling part's head, the overlap tails, and the last shard's wrapped
    tail. Each node also publishes the md5 of its header.
  - **Records and combine:** each node publishes all of this in its rendezvous record
    (`etag_parts`). Every node, rank 0 included, combines all the records and compares.
  - **Failures:** a mismatch (`ErrETagMismatch`) fails the run (exit 1) before any output is
    opened. So does an unverifiable ETag (`ErrETagFormat`: not an md5, as for SSE-KMS, or no
    part size). Setting it without `AK2_ENGINE_N` is a usage error.
  - **Timing:** it is timed as the `etag` phase, with an `ak2-engine etag` counter line that
    carries the extra GET. The `load` line excludes it.

  The in-process engine verifies too. Code:
  `internal/engine/etag.go`, `cmd/aws-kraken2/etag.go`. `rangeread.FileHandler` is now
  `k2probe serve-file`'s handler, shared with the tests. Shard bytes are unchanged.
- The ladder lever library, `scripts/g3/lever.sh` (#50; the #25 ladder build, WP-6), shared by
  both arms and sourced by a body after the preamble. Its header is the function contract, and
  `docs/ladder.md` is the runbook.
  - `lv_nvme single|raid`.
  - `lv_stage_db awscp-default|awscp-classic|s5cmd`. Stock (`awscp-default`) is the AMI's aws
    CLI as shipped, with no config override. `awscp-classic` forces the classic client in a
    private `AWS_CONFIG_FILE`. Each aws client is recorded:
    - the CLI version and the `configure get` value;
    - for `default`, the AMI's `~/.aws/config` and `/etc/aws`;
    - the client it resolves to. For CLI v2 on auto this is the CLI's own rule:
      `awscrt.s3.is_optimized_for_system()` with the CRT process lock as a caveat. It is read
      from the CLI's source and evaluated with its python, with awscrt's optimised-platform
      list recorded. The ladder types are not on that list, so `default` resolves to classic
      on them. Otherwise `unknown`.

    `lv_db_etag` reads back a recorded ETag.
  - `lv_etag`, as its own phase.
  - `lv_fetch_inputs serial|lanes<K> default|classic|crt`, sha256-checked through
    `scripts/g3/fetch.sh`. The client is an argument, so S6 varies only the lane count. `crt`
    sets `multipart_chunksize = 8MB`.
  - `lv_upload_start awscp-default|awscp-classic|awscp-overlap|s5cmd-serial|s5cmd-overlap`
    (`awscp-serial` is accepted as `awscp-classic`), `lv_upload_enqueue` and `lv_upload_drain`.
    - Tool and schedule are separate levers, so S7 is two rungs: s5cmd-serial, then
      s5cmd-overlap.
    - The sha256 is taken on the node at enqueue, before the upload. LOCAL must not change
      until drain.
    - The overlap lane is waited on by PID. It checks every iteration that the body's shell is
      alive, and is killed if drain cannot write END.
  - `lv_gunzip_shim gzip|rapidgzip-P<k>`: rapidgzip 0.14.5 behind a `gzip` on PATH, for
    upstream's `gzip -dc`.
    - It is installed with `pip --require-hashes` against the pinned sha256 of its manylinux
      wheels (aarch64 and x86_64, cp39 to cp313).
    - The record holds the wheel's and the extension's sha256, and the paired concurrency
      (2 shims, 2k threads).
  - `lv_s5`, the only s5cmd entry point: s5cmd 2.3.0, its tarball checked against sha256 pinned
    in lever.sh.
    - It allow-lists buckets.
    - It refuses `run` as any argument, `--endpoint-url`/`-endpoint-url` and a set
      `S3_ENDPOINT_URL`.
    - It parses single-dash long flags.
  - Every call writes a JSON record (streamed as `lever {json}`, pushed to `out/lever.jsonl`)
    and counts its requests with `ak2_req`. Counts from an aws client that did not resolve to
    classic are written as `<op>-estimate` and flagged `estimate: true`. Every failure also goes
    through `ak2_err`.
  - `make lever-test` runs `scripts/tests/lever_test.sh` in AL2023 under podman, with the real
    preamble under `bash -e -c` and stub aws and s5cmd. It checks:
    - the upload overlap by timestamps, against the serial contrast;
    - that the shim is byte-identical to `gzip -dc`;
    - that s5cmd is refused undeclared buckets, endpoints and `run`;
    - that the sha256 is recorded before each upload;
    - that serial and lane fetches both verify;
    - the estimate tagging;
    - the auto rule on AL2023's real `awscli-2` rpm;
    - the hash-pinned installs, and their refusal of tampered files;
    - that failures are surfaced.

    It is not part of `make test`, because it needs podman.
- Host tunes and the tune-selection probe (#41; #25 WP-5, which fixes ladder 1's S3 set);
  docs/probes.md, "Host tunes":
  - `scripts/g3/hosttune.sh`, sourced by a body:
    - `ht_apply none|<set>` sets THP `enabled` and `defrag`, `vm.compaction_proactiveness` and
      `read_ahead_kb`, then runs an optional timed `compact_memory` step. It records every
      knob's before, wanted and after value, and fails loudly when a set does not read back.
    - `ht_restore` returns the host to its boot values.
    - `ht_record LABEL` pushes buddyinfo, the `compact_*` and `thp_*` vmstat lines, the
      huge-page meminfo lines and the THP settings on every call.
    - `none` never writes.
  - `runs/g3-probe-tune-x8g.24xlarge.json` (`scripts/g3/probe-tune.body.sh`), one x8g.24xlarge
    in us-west-2b:
    - 6 sets (`none`, `precompact`, `proactive`, `defer`, `defermadv`, `always`) × 2 regimes
      (upstream `-M` on a huge=always tmpfs staged by s5cmd; ours' engine N = 1 ranged-GET load)
      × 3 repetitions, every trial cold, after a discarded `none` warm-up pair;
    - each repetition complete before the next, in a registered order (`SCHED`): every set's
      regime order flips per repetition, every cell's predecessors differ, every cell has
      2 of its 3 trials right after the other regime, and mean positions are balanced;
    - load, classify, teardown and fragmentation counters per trial, streamed;
    - a network ceiling before and after;
    - the selection rule and the resolution check registered in the spec header.
  - `scripts/lib/tune_tables.py` (the post) writes `tables/probe-tune{,-trials,-selection,-drift}.tsv`.
    - It counts only complete repetitions, and it prints the resolution and the load ceiling
      before any null.
    - It exits 1 if the trials' outputs or reports differ, and 3, with a loud UNDETERMINED line,
      if a regime has no selection (for example after a TTL kill in rep 3).
    - `probe-tune-trials.tsv` records each trial's `prev_regime` and `prev_set`.
    - `make test` runs its `--self-test`, which includes the schedule's properties, read from
      the body.
  - `scripts/g3/mkspec-u.sh` takes an optional ACCESSIONS argument for `env.AK2_ACCESSIONS`.
  - `make hosttune-test` (`scripts/lib/hosttune_test.sh`) runs on an AL2023 podman container.
    `make rehearse SPEC=runs/g3-probe-tune-x8g.24xlarge.json` adds the `tune` kind to
    `scripts/lib/probe_rehearse.sh`: the full plan on the viral DB with a fake `/sys` and `/proc`.
- Accession ranges by reference and a pre-launch vCPU quota check (#47, step 3 of #25):
  - `env.AK2_ACCESSIONS` may be `@<project>:<a>-<b>`, ranks a..b of
    `results/cohort/<project>/runs.tsv`, resolved by `scripts/lib/accessions.sh`. `run.sh`
    expands it into `manifest.sample_accessions` and records `sample_accessions_ref` (reference,
    file, git blob). It refuses a runs.tsv that is uncommitted or locally modified. Only the
    reference goes into the spec env and user data. `run-multi.sh` resolves it before any launch.
    `scripts/g3/mkspec.sh` now writes `@PRJNA398089:1-<COHORT>`.
  - `scripts/g3/campaign.body.sh` resolves the value on the node from its checkout at the run's
    commit and fails unless it names the samples it reads. `make rehearse` passes the spec's
    `AK2_ACCESSIONS` to the rehearsal nodes.
  - `scripts/lib/quota_check.sh REGION TYPE COUNT` maps the type to its on-demand quota family
    (Standard `L-1216C47A`, X `L-7295265B`, and the other EC2 on-demand families) and sums COUNT
    × vCPUs plus the vCPUs of the family's on-demand instances already alive in the region. It
    compares the sum with Service Quotas and refuses if it is over, or if it cannot judge.
    Read-only calls only. `run-multi.sh` checks all NODES before any launch, and `run.sh` checks
    the planned type. Both do this under `DRY_RUN=1` too, and record it as `quota_check`.
  - `make test` runs `scripts/lib/quota_check_test.sh`, a stubbed `aws` in which 1 × x8g.24xlarge
    is allowed and 2 are refused against the 128 vCPU X quota.
    `scripts/lib/run_multi_test.sh` gains the same refusal through run-multi.sh (before any
    launch, under `DRY_RUN` too), plus a bad reference.
  - `make dryrun-userdata [GEN=…]` (`scripts/dryrun-userdata.sh`): `DRY_RUN=1` of every
    `runs/*.json`, plus campaign specs generated in a scratch worktree. It writes user data and
    quota per spec to `results/rehearse/dryrun-userdata-<ts>-<sha>.tsv`.
  - The fixed `AK2_MAX_COST_USD=50` ceiling is removed from `scripts/ak2.env`. Scott ruled on
    2026-10-09 (#25) that there is no budget cap and spend is tracked only. In its place,
    `scripts/lib/cost_check.sh` refuses, as a typo, a `cost_limit` above TTL × the truffle on-demand
    price × (1 + ε) + $0.01 per node. ε is `AK2_COST_EPSILON`, default 0.10, and the cent covers
    rounding to the cent.
    - `run-multi.sh` checks NODES × `cost_limit` before any launch.
    - `run.sh` checks each member for the planned type after the spawn plan.
    - Both do this under `DRY_RUN` too, and record it as `cost_limit_check`.
    - `AK2_MAX_COST_USD` survives only as an optional extra ceiling, unset by default.
    - Per-run TTL and `cost_limit` (TTL × on-demand price) are unchanged and remain the runaway
      backstops.
  - `run.sh` refuses a cohort id whose sha7 is not HEAD's, because the nodes check out that commit.
  - `run.sh` and `run-multi.sh` refuse an `@…` reference when the body never calls
    `accessions.sh`.
  - `cohort.json` records `sample_accessions_ref` as `{ref, runs_tsv, blob}`.
  - Tests:
    - `scripts/lib/run_sh_test.sh` (new, in `make test`) runs the real run.sh in a scratch repo
      with stubbed tools. It covers the cohort sha check and the reference/body check.
    - `quota_check_test.sh` gains the cost_limit cases: c1000 on 32 × c8g.12xlarge is allowed,
      typos are refused, and the override and a missing price both refuse.
    - `run_multi_test.sh` gains the typo refusal (also under `DRY_RUN`), the body check and the
      cohort.json record.

- Utilisation on every AWS run, on both arms (#25; Scott's definition, 2026-10-09):
  - `scripts/util-sampler.sh`: a 1 Hz, dependency-free bash sampler (no fork per tick). It
    records raw `/proc/stat`, meminfo, vmstat and interface counters, the task cgroup's
    `cpu.stat` and the current phase, plus `ethtool -S` `*_allowance_exceeded` at start and end.
  - `scripts/lib/mkstub.sh` splices the sampler into the user-data stub, which starts it before
    anything else.
  - The preamble streams the record to `log/util.tsv` every 30 s from the pusher. `ak2_phase`
    takes a boundary tick, and `ak2_finish` takes a `final` tick before the last push.
  - `run.sh` records `instance.type_info` at launch: vCPUs, MiB, and the baseline and peak Gbit/s
    from describe-instance-types. It keeps the launched stub as `stub.sh`.
  - `scripts/lib/util.py` writes `tables/util.tsv`: per-node, fleet and per-phase U_cpu,
    U_mem (mean and peak) and U_net (at the baseline and the peak rate), each with its own
    effective cost and multiplier, plus the unobservable-window durations. `run.sh`,
    `run-multi.sh`, `refinalise.sh` and `make report` call it. `make test` runs its unit test
    (`scripts/lib/util_test.py`).
  - `make util-stream-test`: on N AL2023 containers running the real stub and preamble, checks
    that the record streams on every node and resolves known CPU, tmpfs and network effects.
    `make rehearse` runs it first. `BREAK=nopush|nostub` are negative controls.
  - `make util-backfill`: lower-bound utilisation of the existing `results/g2` and `results/g3`
    runs. It draws on the engine's getrusage and memory samples, the G2 runner's and loadbench's
    per-run getrusage, and the logged byte counts. It has explicit coverage and arm columns;
    upstream peak RSS is reported as `rss_peak_gib`, not U_mem. Written to
    `results/util-backfill/`.
  - Review fixes before merge:
    - fleet numerators and denominators now cover the same nodes;
    - memory gaps are no longer interpolated (`mem_gap_s`);
    - network is counted from boot, with per-direction U_net_rx/tx;
    - backwards counters give empty cells plus a note;
    - the sampler looks the interface up again after a late default route;
    - util.tsv is re-uploaded every 30 s (the TTL-kill loss is bounded, and the test asserts it);
    - cohort rows are labelled by run_id;
    - a `tables/util.json` sidecar is written.
    - a late interface's since-boot counter is counted in the boot window;
    - the sampler renices itself to -10 (`H nice`), and util.py reports the largest tick gap
      per phase;
    - the streaming test runs the stub under `bash -e -c` and rootful, adds a saturating
      `starve` phase (it asserts `mem_gap_s` = 0), and adds a one-node round that checks the
      CPU, memory and network magnitudes from above.
  - `make instance-types`: `results/instance-types/us-west-2.json`.
  - Runbook `docs/util.md`.

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- Run harness: `make run` (`scripts/run.sh`, on-instance hygiene preamble `scripts/preamble.sh`,
  settings `scripts/ak2.env`), `make orphans`, `make report`, with runbooks `docs/run.md`,
  `docs/orphans.md`, `docs/report.md` and the spore.host brief `docs/spore-host.md` (#1).
- `internal/kdb`: `opts.k2d` (IndexOptions, legacy 48/56-byte layouts), `hash.k2d` header, and
  32/40-bit cell-width detection cross-checked against object size; `cmd/k2probe header|opts` (#3).
- G0a spec `runs/g0a.json`, post-processing `scripts/post/g0a.sh`, and its runs under
  `results/g0a/` (#3).
- Harness hardening from the law review:
  - a bucket allow-list (`AK2_DATASETS`), checked statically and on the instance by an `aws`
    PATH shim;
  - `inputs[]` refused in favour of `ak2_stage`;
  - the wrong-region launch is terminated;
  - disowned log tee and pusher;
  - Payer, TTL and cost ceilings, env-key and dirty-tree refusals;
  - a `drop_caches` probe;
  - `ak2_phase` timings and `ak2_req` request counts;
  - an all-region orphan sweep;
  - an ETag check in `scripts/post/g0a.sh`.
- Re-review fixes:
  - a finish handler that survives a process-group SIGTERM and logs the real exit status;
  - a checked log-tee start;
  - `set -e` refused in specs;
  - `ak2_req` validation;
  - `cold` markers in `phases.tsv`, with `ak2_drop_caches` fatal (exit 95) when caches can't be
    dropped;
  - placement/spot refused, an env-key allow-list, and a wider dirty-tree check;
  - in-flight phases recorded on a kill;
  - `readonly -f` on the helpers.
- Follow-ups:
  - a shell-aware errexit check (`scripts/lib/errexit_check.py`, self-tested in `make test`),
    backed by runtime `$-` checks;
  - a PIPE trap;
  - `ak2_req` bucket validation;
  - helper errors and state kept in files, so subshell errors count;
  - KILL for a hung tee;
  - shim content and self-test verification.
- `run.sh` records its post-run orphan check: `<run dir>/orphans.txt`, plus
  `manifest.orphan_check` (rc, own_gone, other live instances with flags, regions checked and
  failed). `make report` shows it as a row.
- Orphan check scoped per run:
  - `run.sh` now runs `scripts/orphans.sh --own <task_id> <instance_id>`, which fails only if
    its own instance survives;
  - concurrent runs' instances are listed as informational;
  - instances past their `spawn:ttl-deadline` + 15 min are flagged as probable orphans;
  - `make orphans` stays global and strict, for when no runs are in flight.
- Pin identity is the commit SHA: every manifest writer (`run.sh`, `oracle.sh`, `g0b.sh`,
  `equiv-seqout.sh`, `classify-oracle.sh`, `harness-build.sh`) records the full upstream SHA and
  its `git describe --tags`, computed by `scripts/pin-identity.sh` from `scripts/pin.env` and
  the oracle source checkout.
- `make tag-objects` (`scripts/tag-objects.sh`, `docs/tag-objects.md`): `project=aws-kraken2`
  plus `kind=data|payload|results` on every object under the project prefix. `stage-db.sh`,
  `stage-reads.sh` and `run.sh` tag at write time, and `run.sh` tags the run prefix after each
  run (the instance role cannot tag). The first run tagged 134 objects.
- spawn 0.123.0: `scripts/udsize` is bumped to v0.123.0. The user-data builders were re-read
  (only the bootstrap's #707 `$-` announcement changed).
- User data:
  - `command[2]` is now `scripts/stub.sh` (region assert, presigned GET, sha256 check, exec);
    the preamble and body travel as `<run prefix>/payload.sh`;
  - `run.sh` measures the exact user data with spawn v0.121.0's builders (`scripts/udsize`)
    and refuses within 1024 bytes of EC2's 16384-byte cap, including under `DRY_RUN`.
- `internal/chash`: port of upstream's compact hash lookup path (fmix64, 32- and 40-bit cells, linear and double probing, RAM and mmap loaders, `CellSource` probe over `io.ReaderAt`); `upstream/chash_dump.cc` and `upstream/chash_keys.cc` oracle harnesses; `k2probe equiv-hash`; `make harness` and `make g0b` (#4).
- `internal/mmscan`: port of upstream's `MinimizerScanner` (DNA and protein, both revcom versions,
  `LoadSequence` intervals, zero allocations per minimizer). It is checked against upstream by
  `upstream/mm_dump.cc`, `k2probe equiv-scan` and `make g0b PART=scan`. `scripts/harness-build.sh`
  builds the oracle harnesses (#5).
- `internal/taxo`: `taxo.k2d` reader ported from upstream `taxonomy.{h,cc}` (node fields, names,
  ranks, external-ID map, `IsAAncestorOfB`, `LowestCommonAncestor`, the `taxo.Tree` interface),
  checked against upstream's own `Taxonomy` class via `upstream/taxo_dump.cc` (#11).
- `internal/report`: kraken-style `--report` and `--use-mpa-style` ported from upstream
  `reports.{h,cc}`, including `--report-zero-counts` and libstdc++'s `std::sort` tie order for
  siblings; byte-identical to upstream's reports on real reads (#15).
- `scripts/harness-build.sh`: builds `upstream/<name>.cc` oracle harnesses against the pinned
  sources with upstream's compiler flags.
- `internal/seqio` (FASTA/FASTQ reader ported from upstream `fast_reader`, two-file and interleaved
  pairs, gzip/bzip2 input with the wrapper's detection and `gzip -dc`'s behaviour on damaged
  streams, quality masking with Linux aarch64 unsigned-char semantics) and `internal/seqout`
  (`--classified-out`/`--unclassified-out` writers; `seqout.Ordered` restores batch order in the
  seqout oracle test, while the CLI orders its output with its own pwrite sequencer). `make equiv-seqout`
  checks both byte-for-byte against upstream on Viral (#12, #16).
- `internal/classify`: per-read classification (ClassifySequence's minimizer loop, ResolveTree,
  `--quick`, `--confidence`, `--minimum-hit-groups`, `-F`) and the `--output` line (#13, #14), with
  the `upstream/classify_trace.cc` oracle harness, `make harness` and `make oracle-classify`.
- `cmd/aws-kraken2`: the classifier CLI. Its command line is upstream's `kraken2` wrapper's
  (Getopt::Long parsing, defaults, `find_db`, validation, messages, exit statuses, compression
  auto-detect), followed by classify's own checks and run: a sequential block reader, N workers
  with per-worker buffers and counters, output written in input order by pwrite at prefix-sum
  offsets, and the report from merged counters. `--report-minimizer-data` (#18) and
  translated-search databases are refused.
- `make oracle` (#17, `scripts/oracle.sh`, `docs/oracle.md`): upstream's `kraken2` vs
  `bin/aws-kraken2` on real reads (SRR062634, ERR478965, SRR28305653 and awk variants for `/1`
  `/2` IDs, mates shorter than k and unequal mate files) against Viral and/or Standard-8. It
  byte-compares `--output`, `--report`, the sequence outputs, stdout and the exit status, runs
  coverage checks, negative controls and matrix-integrity checks (requested outputs exist,
  nothing unrequested is written, every case recorded, a filter must match), covers standard
  output, FASTA, bzip2, `KRAKEN2_DB_PATH`/`KRAKEN2_NUM_THREADS` and unwritable outputs, and
  writes `results/g1/oracle-<db>-<ts>/`
  (`manifest.json`, `cases.tsv`, `checks.tsv`, `summary.md`).
- CI (#20): `.github/workflows/ci.yml` runs build, test and `go test -race ./...` (oracle-backed
  tests required, `AWS_KRAKEN2_REQUIRE_ORACLE=1`, with `AWS_KRAKEN2_DBS` naming the databases
  the job provides), lint with a pinned staticcheck, and `make oracle DB=viral` on
  `ubuntu-24.04-arm`. The `.oracle` cache key includes the compiler version.
- `runs/g1-oracle.json`: TaskSpec for `make oracle DB=all` on Graviton in us-west-2, the
  canonical evidence for both databases. Prepared, not launched. `make stage-db`
  (`scripts/stage-db.sh`) and `make stage-reads` (`scripts/stage-reads.sh`) make the in-region
  database and read copies it stages and verifies, so the run depends on neither genome-idx nor
  ENA. Setup steps fail fast; the oracle streams into the run log; only this run's result
  directories are pushed, and push failures count into the exit status.
- `classify.Calls`: report input from merged counters, keeping zero-read taxa, with an end-to-end
  counters-to-report test.
- `upstream/chash_build.cc` and a g0b `hash` sub-step: a synthetic 40-bit table built by
  upstream's own `CompareAndSet`/`WriteTable` (linear and double-hashing builds), looked up by
  upstream and by `internal/chash`, so the 40-bit cell path is checked against upstream.
- `docs/harness.md` runbook; `scripts/cxx.sh` is the compiler choice shared by the upstream build
  and the harnesses.
- `make bracken-check` (#19, `scripts/bracken-check.sh`, `docs/bracken-check.md`): runs Bracken
  v3.1 (`est_abundance.py`, levels S and G, `-r 100`) on upstream's and our `--report` for
  Standard-8 on ERR478965 and SRR062634, and byte-compares the reports, Bracken's tables, its
  adjusted reports and its stdout. Writes `results/g1/bracken-<ts>-<sha>/`.
- `make loadbench` (#36, `scripts/loadbench.sh`, `docs/loadbench.md`): load-path and
  whole-process wall time of upstream and ours (plus a per-change ladder of our builds) on one DB
  and thread count, cold and warm, with an optional perf/pprof profiling mode; TaskSpecs
  `runs/loadbench.json` (m7g.2xlarge) and `runs/loadbench-g4.json` (Graviton4). `aws-kraken2`
  writes a per-phase timing log with `AK2_TIMINGS=1` and a CPU profile with `AK2_CPUPROFILE`
  (the default stderr is unchanged). `chash.LoadFrom` with a `Filler` interface (`ParallelPread`)
  fills the table buffer, so a later S3 ranged-GET loader can fill the same buffer.
- G0c (#7, #8): `make g0c PART=local|probes|runs` (`scripts/g0c.sh`, `docs/g0c.md`, specs
  `runs/g0c-{runs,probes}.json`, post scripts `scripts/post/g0c-{runs,probes}.sh`).
  `internal/runlen` measures the occupied-run structure of a hash.k2d with parallel chunk scans,
  an in-order merge, and a brute-force reference: the run histogram (wrap run joined), the
  longest run, the overlap tail per shard count, and Borel theory. `internal/rangeread` is an
  in-order streaming reader over parallel ranged reads (file, or anonymous HTTPS with If-Match).
  `k2probe runs` does one pass, SHA-256 included, and `k2probe probes` samples classify's
  lookups from real reads and resolves them with point GETs through `chash.Probe`.
  `make stage-reads` now also stages ERR598966.
- `make sortfuzz [SORTFUZZ=quick|full]` (`scripts/sortfuzz.sh`, `docs/sortfuzz.md`): a
  differential fuzz of `internal/report`'s `stdSort` against libstdc++'s `std::sort`
  (`upstream/sortfuzz.cc`, `internal/report/sortfuzz_test.go`) with upstream's report comparator.
  The full corpus has about 10^6 heavy-tie cases, every n from 0 to 2048, and McIlroy
  median-of-3 killers. Each case reports whether the heapsort fallback ran, detected by a
  `std::__partial_sort` specialization on the harness's own iterator type. A CI job runs the full
  corpus in `amazonlinux:2023` (GCC 11.5.0) (#35).
- G2 (#21, #22, #23): `make g2 PART=local|summary` (`scripts/g2.sh`, `docs/g2.md`) runs a
  checked-in plan (`scripts/g2/*.plan`) of upstream rungs in four regimes (default load, `-M` on a
  huge=always tmpfs, `-M` on NVMe, and the diagnostic `kraken2-madvrandom`), each instrumented by
  `scripts/lib/g2run.py` (classify-window `/proc/vmstat` and `/proc/diskstats` deltas, `perf stat`
  enabled through a control fifo, a per-thread state and syscall sampler), and summarised by
  `scripts/lib/g2summary.py` (cells with median and range, ladders with step efficiency and
  resolution, gz vs plain, per-candidate signature tables). `scripts/g2-instance.sh` does the
  instance setup (NVMe RAID0, RODA v205 staged and checked against its ETag with
  `scripts/lib/etagcheck.py`, reads and derived subsets, builds). `scripts/madvrandom-build.sh`
  builds the diagnostic `upstream/madvrandom.patch` variant into its own directory; the oracle
  build stays pristine. Plans can set the host `read_ahead_kb` (`readahead`), and the summary flags warm cells that did not follow their own input. Plans can also set THP, a command prefix (numactl) and switch instrumentation off for a control. Specs `runs/g2-{smoke,nvme,nvme2,nvme3,ram,ram2,c8gd,c9gd}.json`. `make stage-reads` takes
  `STAGE_READS_N` and `STAGE_READS_RUNS` (the SRR062634 8M-pair subset).
- G3 engine, in-process (#24, checkpoint 1). `internal/engine` provides:
  - the sharded resident table: floor-cut slot ranges (`Cut`, `Owner`), each loaded with its
    overlap tail and wraparound through a context-aware parallel ranged-read `Filler` into an
    off-heap huge-page region (`chash.AllocRegion`). The tail is verified at load (an empty cell
    at or after the last owned slot), so a probe never leaves its shard;
  - a router that batches each input block's lookups by owner shard and gathers the values back
    in order;
  - in-process and TCP transports, the TCP one with length-prefixed batches and a hello that
    checks the shard, shard count, capacity and run token.

  `bin/aws-kraken2` uses the engine when `AK2_ENGINE_N` is set (`AK2_ENGINE_TRANSPORT`,
  `AK2_ENGINE_TAIL`; `AK2_TIMINGS=1` adds per-shard load phases and `ak2-engine` counters).
  `make oracle-engine` runs the whole oracle matrix through it at each N
  (`scripts/oracle.sh` `ORACLE_ENGINE`; docs/oracle.md, "Engine mode").
- G3 engine, multi-node (#24, checkpoint 2; docs/engine.md):
  - one process per node (`AK2_ENGINE_RANK`), peer discovery through an S3 (or directory)
    rendezvous, and shards loaded by ranged GETs of the object;
  - each block classified on its home node and sent to the emitter (rank 0), which writes the
    outputs in read order, as local files or as one S3 multipart upload per output (parts of
    at least 8 MiB, numbered in read order), with flow control and the report's sum-reduce;
  - `internal/objstore`: the aws CLI, or a local emulation with S3's part rules;
  - transport deadlines and a table identity in the shard hello;
  - `make oracle-engine TRANSPORT=procs` (N processes over loopback; also in CI);
  - `make run … NODES=n` (`scripts/run-multi.sh`): a cohort of n `run.sh` runs with one cohort
    id. It checks the security group, the AZ and the total cost; afterwards it fetches the
    cohort prefix, aborts unfinished uploads, writes `cohort.json` and runs the global orphan
    check;
  - spec `runs/g3-std8.json`.
  - review of b78afbc:
    - `run-multi.sh` has a finish trap on every exit path (aborts unfinished uploads, writes
      `cohort.json`, runs the orphan check, terminates the members if interrupted), fails fast
      (terminates the other members when one fails), and refuses a security group that admits
      more than itself, 22/tcp and ICMP;
    - presigned URLs are redacted from `rangeread` errors (URL query, `*url.Error`, S3 error
      bodies);
    - the multipart upload is created lazily, so an empty output is one PutObject;
    - after an engine failure, uploads are aborted rather than completed truncated;
    - the emitter validates Result frames (owner rank, input, once) and checks each node's Done
      against what arrived and its own cut;
    - a race in `nd.stopped` is fixed, and an in-process 3-node test runs under -race.
  - review of a7b0f0b:
    - member drivers run in their own process groups, and `finish` stops them (TERM, then
      KILL) before it sweeps, waits for termination, sweeps again and only then aborts
      uploads;
    - sweeps repeat after a fail-fast, sweep failures are recorded and exit 6, and the cohort id
      has a random suffix;
    - `scripts/lib/run_multi_test.sh` (stub simulation) runs in `make test`.
- G3 sweep build (#25, docs/cohort.md):
  - `make stage-cohort`: the first 1000 PRJNA398089 paired WGS runs, recorded before use
    (`results/cohort/PRJNA398089/runs.tsv`); md5-checked staging, with `runs/stage-cohort.json` to
    stage from an instance;
  - cohort mode (`AK2_COHORT`): one engine process per node over a sample list, the shard loaded
    once, sample-parallel (each sample's home node is its emitter) or block-striped, samples in
    flight per node, batches with barriers, and per-sample `ak2-sample` records;
  - an aws-sdk-go-v2 S3 store (the default; the CLI is kept selectable), which enforces
    `AK2_ALLOWED_BUCKETS` itself, `s3://` reports, and a fake S3 for tests (`k2probe fakes3`);
  - `make oracle-cohort`: per-sample byte-identity of cohort mode against upstream at N=1 and N=3
    (parallel, striped, SDK), also in CI;
  - `scripts/upstream-cohort.sh`: the upstream arm (huge=always tmpfs, `-M`, the same manifest);
  - `runs/g3-e1.json`, the calibration run, with the tidy-table post scripts
    (`scripts/lib/tidy.py`, `scripts/post/g3-e1{,.cohort}.sh`; run-multi runs a cohort-level post);
  - an `ak2-engine result` line;
  - fixed a data race in `TCPClient.dial` (Lo and Hi were written on every concurrent dial).
- `make hitorderfuzz [HITORDERFUZZ=quick|full|selftest]` (`scripts/hitorderfuzz.sh`,
  `docs/hitorderfuzz.md`, `internal/classify/hitorderfuzz_test.go`): a differential fuzz of the
  `HitCounts` from `newHitCounts()` against `std::unordered_map` under Amazon Linux 2023's
  g++ 11.5.0 (`upstream/umap_order.cc`, natively or in podman). It compares orders and counts at
  every print of seeded histories (random, lookup-heavy, clear cycles, growth across every rehash
  boundary up to 10^5 elements, and the #44 reads), stops at the first mismatch, and fails on
  unmet coverage. `umap_order` gains the ops `N`, `V`, `B` and `G`; existing histories are
  unchanged. A CI job runs the full corpus in `amazonlinux:2023` (#44).
  - `HITORDERFUZZ_SENSITIVITY=reversed|first-hit` records a sensitivity run that must fail.
- LPT sample placement in cohort mode (`parallel:lpt`, `weight=<n>`; `cmd/aws-kraken2/place.go`),
  with j mod N kept as `parallel:mod`, the control. `make oracle-cohort` gains `n3-lpt` and checks
  every observed home rank against the manifest's placement (`scripts/lib/lpt_check.py`) (#25).
- Engine memory samples: an `ak2-engine mem` line every 15 s with `AK2_TIMINGS=1` (#25).
- The campaign memory rule: `scripts/g3/mkspec.sh` and `make rehearse` require the shard plus
  15%, 8 GB, and 7.5 GB per sample in flight, measured (`scripts/lib/g3_memory.py`) (#25).
- `make bash-jobs-test`: the body's job control under AL2023's bash, in podman
  (`scripts/tests/bash_jobs.sh`). The old fetch loops must fail; the current fetch and PID lanes
  must pass (#25).
- `k2probe diag-reads`: the per-read Law-1 diagnosis. It compares scanner events with ambiguity
  flags, lookups with probe counts against upstream's CompactHashTable (`chash_dump -m`),
  upstream's values, and ResolveTree's arithmetic. It runs on RODA through
  `runs/g3-diag44-r8gd.16xlarge.json` (#44).
- `k2probe taxo-orphans`: lists taxonomy nodes whose lineage does not reach the root. RODA v205
  has 246 (#44).
- The G3 campaign tooling:
  - `make g3-spec`, `make g3-tables` and `make g3-law1-u2`;
  - U1 and U2;
  - `make hitorder-golden`;
  - `scripts/lib/abort_uploads.sh` (#25).

### Changed

- Classification speed (#39, #36). `mmscan.Scanner.AppendMinimizers` runs the scanner loop over
  a whole sequence with its state in locals, and `classify.Tokens.Scan` uses it, with
  MurmurHash3 called directly for the capped-database check. Its output is held to `Next`'s by
  a test, and keeps the reverse complement incrementally. The second mate's block is sized like
  the first's. (`seqio.Recycle`, block reuse, was measured and reverted: no gain.) `chash.GetBatch` resolves a read's lookups with their cache misses
  overlapped. It returns the same values as `Get`, checked by a test and by `k2probe equiv-hash`
  against upstream. `AK2_MEMPROFILE` writes an allocs profile.
- `make loadbench`:
  - the implementation order rotates per repetition;
  - the manifest records the database's storage (device, model, EBS volume);
  - the summary states the cold load rate and shows ranges in the attribution table;
  - a per-cell noise floor from A/A control rungs (same binary, consecutive in the ladder):
    the larger of their largest |Δ median| and half their median range width, with the number
    of pairs stated;
  - one verdict rule for attribution rows and the per-cell acceptance table against upstream:
    within noise (below floor), above floor with ranges overlapping, or ranges separated;
  - `LB_REPS_COLD` / `LB_REPS_WARM` set per-state repetitions;
  - `LB_WARMUP` / `LB_WARMUPS` add unrecorded cold warm-up runs, kept in the manifest;
  - `LB_READS`, `LB_PROFILE_IMPLS` and `HEAD` in the ladder are new;
  - `runs/loadbench-g4.json` uses instance-store NVMe (r8gd/c8gd).
- One `cmd/k2probe` dispatcher, with commands registered from `init()`. `header`/`opts` moved
  into their own files, and `equiv-scan` reads `opts.k2d` through `internal/kdb`.
- `scripts/harness-build.sh [-v lp|dh|lp,dh] [name...]` is one interface for every caller:
  - flags and LDFLAGS are read from upstream's Makefile, and it fails without `-DLINEAR_PROBING`;
  - it keeps one archive per variant, keyed by pin, compiler, flags and sources, and refuses a
    modified upstream tree;
  - binaries go under `.oracle/harness/<pin>/`, with a `.BUILD` record per binary.
- Shared `.oracle`/`.cache` resolve only through git's common dir. Scripts use
  `scripts/paths.sh`, tests use `internal/oracletest`, and `oracle-build.sh`, `fetch-db.sh`
  and `fetch-reads.sh` now use it too. `oracletest` reads the pin from `scripts/pin.env`, and
  `AWS_KRAKEN2_REQUIRE_ORACLE=1` turns skips into failures.
- `scripts/g0b.sh hash|scan|all`:
  - one `G0B` variable (`PART` accepted);
  - run IDs are UTC time plus short sha, and an existing results dir is refused;
  - a manifest per step, with the DB ETag inline;
  - a missing DB, read set or key population, or zero comparisons, now fails the run.
- `fetch-db.sh` falls back to HTTPS when the AWS CLI is absent.
- Dedupe: `internal/classify` uses `chash.MurmurHash3` and `seqio.MaskLowQuality` (unsigned),
  and its own copies are gone.

### Fixed

- `scripts/lib/util.py`: the fleet row's `allowance_exceeded` was always empty, because the
  fleet aggregate had no allowance (#58). It now sums each ethtool `*_allowance_exceeded`
  counter's delta over the fleet's nodes, in the node rows' `name=value;…` form, and coverage
  names any node that lacks the counters or one of them. Phase rows stay empty: the counters are
  read only at start and end. `results/g3/20261009-223514-4ee77c3/tables/util.tsv` and its
  `util.json` were regenerated with the fix.

- Law 1 on RODA v205 (#44). ResolveTree walked the hits in first-hit order, but upstream walks
  its per-thread `std::unordered_map` hit_counts (classify.cc:897-949). When a score tie's
  LowestCommonAncestor is 0, which an orphan taxonomy node produces, the call depends on that
  order. The fix routes the walk through `HitCounts` (`internal/classify/hitorder.go`), with a
  clean-room implementation of the container's order (`hitcounts.go`, 904c2a5). It is checked
  three ways:
  - golden op histories from GCC 11.5.0 on AL2023;
  - a differential fuzz;
  - `TestIssue44OrphanTies` on the 16 real reads.
  The RODA recheck then gave 0 differing reads on the 3 affected HMP2 samples, with digests
  equal to upstream's (results/g3/20261009-015708-210e1b5).

- `chash.Load` (#36): the table is 2 MiB-aligned and advised `MADV_HUGEPAGE`, as in upstream's
  LoadTable. Under THP mode `madvise` (Amazon Linux 2023's default) it was on 4 KiB pages, which
  meant one fault per 4 KiB at load and as many PTEs to tear down at exit.
- `aws-kraken2`: an unwritable `--report` is silently not written and the run exits 0, as with
  upstream's unchecked ofstream (it exited 1). "Unable to open file" reasons are worded as C's
  strerror.
- `fetch-reads.sh` uses `sha256sum` when `shasum` is absent and fails on an empty hash. It retries
  ENA requests (the portal API with `--retry-all-errors`; the FASTQ stream with `--retry`, plus a
  retry of the whole pipeline) and fails loudly when the retries run out.
- CI uploads only the result directories the run created, not the committed ones, in an
  artifact named for the PR head commit.
- Oracle-backed tests no longer call `t.Skip` directly: they skip through `oracletest`, so
  `AWS_KRAKEN2_REQUIRE_ORACLE=1` fails them. Every one of them runs in CI against Viral: the
  classify traces come from `scripts/classify-oracle.sh`, and the seqio/seqout oracles from
  `make equiv-seqout` (via `.cache/equiv-seqout/latest`). CI prints a ran/skipped summary of
  `go test -race -v ./...`.
- `fetch-reads.sh` checks FASTQ structure, and retries the FASTQ stream as a whole pipeline
  rather than with curl `--retry`. `stage-reads.sh` and the G1 spec check that each gzip copy
  decompresses to the FASTQ its SOURCE names. The spec stages only the declared read files.

- `internal/chash`: `32 + capacity × cellBytes` is checked for overflow, so a crafted header can
  no longer pass the size check into an out-of-bounds slice. The header is decoded by
  `internal/kdb` and the file size checked with `kdb.CellWidth`. `ReaderAtSource` accepts a full
  read returned with `io.EOF`.
- `internal/mmscan` golden tests fail, rather than skip, when a golden stream is missing.
- `internal/report` oracle: each resolution control must fire at least once per database.
  `stdsort.go` carries a provenance note (libstdc++ `stl_algo.h`/`stl_heap.h`, HP 1994 / SGI 1996
  STL).
