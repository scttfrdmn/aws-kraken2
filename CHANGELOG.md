# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The ladder's O arm for c10 stages 4–7 and any cohort** (Scott's rulings of 2026-10-13, #25;
  docs/ladder.md, "The O arm's thread ratio", "O2 at N = K", "Conditional not-run entries").
  - **Thread ratio (ruling 1).** Every O rung's THREADS is `@ratio:Sstar-time` (`Sstar-cost` on the
    cost chain), which resolves to `vcpus/R`. Its samples at once (PROCS, or INFLIGHT on the engine) are
    `@ratio:…:fill`, which resolves to `fill/R` = vcpus // (vcpus/R). R is S\*'s vCPUs / S\*'s THREADS,
    so O0 is still S\*'s exact configuration.
    - At c10 with S4 → S4-t16 and S\* = S9, R = 6. On a 192-vCPU S\* host, R = 12, because the S
      arm carried T = 16 absolutely there; this reading is flagged.
    - The generator writes fill/R's value at the spec's pinned type. `resolve()` refuses an O rung
      that would oversubscribe its host. The c1 specs are unchanged (R = 1).
    - The engine's INFLIGHT is clamped to the cohort (`fill/R/C`). PROCS is not, so O0 keeps S\*'s
      exact PROCS. At c10 only 192-vCPU S\* cases change (12 or 16 → 10 in flight), and no O3 floor
      type moves.
  - **O2 at N = K.** O2-r8g, O2-x8g and their -cost copies have `instance @fit:<family>`, the family's
    smallest type holding the rung at O1's N = S8's K. That is r8g.48xlarge and x8g.24xlarge at
    N = 1, and r8g.24xlarge and x8g.12xlarge at c10's N = 2.
    - Their "N = 1's" not-run entries above c1 are gone, so O2 and O2-cost are no longer BLOCKED at
      c10.
    - O2-cost-r8g and O2-cost-x8g get conditional c10 `alias_cohorts` entries.
  - **`candidate_out`.** A candidate whose value of its alias's group is the predecessor's own is
    outside the alias's candidates. Examples are O2-x8g on O1's type, and O3-n2 at O2's N = 2 at
    c10, where it would change only the host.
    - The generator refuses it, ladder-select leaves it out, and ladder-advance shows `out`.
    - The function also holds the bracket and range checks.
  - **Conditional not-run entries** (`c<C>: <reason> (if same configuration)`). O1 and O1-cost are
    not run at c10, c100 and c1000 exactly where S8 keeps K = 1, which leaves O0b's configuration.
    The tables decide such entries by the generator's rule (`not_run_cond_checks`).
  - **r8gd floor (ruling 3).** `@floor` on an r8gd host uses r8g's types.
  - **O4b single candidate (ruling 2).** Its margin is `single candidate, not measured: …`. The tables
    label it so:
    - deltas.tsv gives no delta;
    - pairs.tsv gives a labelled lever row with no delta and no step, outside the lever sum;
    - it is never a measured zero.
  - Tests:
    - `ladder_levers --self-test` covers the ratio on every type, O0 = S9 at c10, the N = 2 types,
      O1's conditional not-run, O3-n2 out, r8gd → r8g, and the conditional aliases below;
    - ladder_select_test case 16 covers the O4b label.

- **TTL estimates above c1** (`scripts/lib/ladder_ttl.py`; docs/ladder.md, "TTL above c1"). Above
  c1, `mkspec-ladder.sh` no longer needs `TTL=`. It estimates each rung's wall from the record's c1
  runs of the rung, or of its nearest measured relative (`config_row` at c1, then its predecessors).
  - **The model:** a fixed part, plus per-sample parts scaled by the samples' real pairs and bytes.
    The per-sample parts are the per-invocation time (classify − classify-process), classification,
    serial upload, fetch-inputs and identity. They are split over replicas and PROCS/INFLIGHT lanes,
    with a thread slowdown.
  - **TTL** = max(30 min, 2.5 × estimate), rounded up to 10 min. cost_limit = TTL × price. A TTL
    above `AK2_MAX_TTL_S` is refused (exit 5).
  - The estimate and its basis go into the spec's TTL comment. `make ladder-respec` re-estimates
    such specs.
  - The self-test works the model by hand. On the committed record, S0-T1 at c10 gets 320 min
    (7589 s), under the 8 h limit.
- **O4b and O4b-cost candidate rungs.** O4b and O4b-cost are now aliases over O4a (O4a-cost) and
  O4b-if1 … O4b-if128 (O4b-cost-if…), INFLIGHT k.
  - Statically, every candidate is not run at c1, and none is run where k > cohort.
  - Above c1, a new `range:` clause in the rule (`ladder_levers.inflight_range`) leaves out a
    candidate above max(1, vCPUs // THREADS) on O4a's host, or at O4a's own INFLIGHT. The generator
    refuses it, and ladder-select leaves it out.
  - Where only O4a is left, ladder-select writes O4a as the winner (margin `single candidate`, no
    runs needed). With S4 → S2a (THREADS = vcpus), O4b can never vary at that cohort.
- **c10 conditional `alias_cohorts` entries** on the cost chain's run rungs (O0-cost, O0b-cost,
  O1-cost, O3-cost-n\<K\>, O4a-cost, O4b-cost-if1…8, O5-cost), so a cost rung that coincides with
  its time counterpart at c10 reads its runs instead of being refused.
- **`make ladder-advance COHORT=<c> [DRY_RUN=1]`** (`scripts/g3/ladder-advance.sh`,
  `scripts/lib/ladder_advance.py`; docs/ladder.md, "Advancing a cohort"). One step of a cohort above
  c1, stage by stage:
  - it runs ladder-select, generates every spec now determined and not committed, and runs the
    static checks;
  - it prints the stage plan: the rungs per stage with their state and why, the pending and BLOCKED
    selections, the blockers, and the rehearsal classes;
  - it gives each stage's summed cost_limit as an upper bound. For a pending rung, that is the
    largest over the combinations of the pending selections;
  - it writes `results/g3/ladder-advance/c<c>.plan.tsv`;
  - it stops for the coordinator. It never launches or commits.

  `make ladder-advance-test` is in `make test`.
- `make rehearse SPEC=` accepts specs above c1. It runs the cohort's C samples (the real read sets
  repeated under distinct names, each checked against its oracle), and makes the nodes' `nproc`
  report the spec type's vCPUs (`OMP_NUM_THREADS`), so vcpus ratios give the spec's lanes.

- **Conditional `alias_cohorts` entries** (`c<C>: <rung> (if same configuration)`;
  ladder_levers.py `alias_state`, ladder_tables.py `alias_cohort_checks`; docs/ladder.md, "The
  cost chain reads the time chain"). Such an entry is an alias where the two rungs resolve to one
  configuration. Where they resolve and differ, the rung is an ordinary rung: generated, and read
  from its own runs. While either is unresolved, it is refused (undecided). An unconditional entry
  that differs is still refused, and an undeclared coincidence still is too. The tables apply the
  same rule. `make ladder-check` lists each conditional entry's state.
  - At c1, O3-cost-n2 … O3-cost-n32, O4a-cost and O5-cost are declared conditional aliases of
    their time counterparts. O3-cost-n\<K\> is an alias there, since O2 → O1 and O2-cost → O1-cost
    are both on x8g. O4a-cost and O5-cost stay undecided until O3 and O3-cost are selected.
  - Tests: the self-test covers the alias, own, undecided and false-unconditional cases. N3 in
    `ladder_levers_tables_test.py` checks that the tables read the target's runs where the pair
    holds, the rung's own runs where it differs, and that the same pairs declared unconditionally
    are a DEFECT.
- c1 specs `runs/g3-l-o3-n{2,4,8,16,32}-c1.json`: 2 × x8g.12xlarge, 4 × x8g.8xlarge,
  8 × x8g.4xlarge, 16 × x8g.2xlarge and 32 × x8g.2xlarge.
- **Body-compatibility declarations** (`scripts/g3/ladder.body-compat.tsv`,
  `scripts/lib/ladder_body_compat.py`; docs/ladder.md, "Body changes and finished runs"). A row
  declares that one version of the ladder body and the next leave named classifiers unaffected.
  `make ladder-campaign`'s done check then counts a finished run whose spec differs from the
  committed one only in the body, when a chain of rows covers its classifier. Anything else in
  the spec must still be byte-identical.
  - The rows are checked mechanically (`make ladder-compat-check`, in make test). Both versions
    must be in HEAD's history, with `commit` an ancestor of HEAD holding the newer one. The
    classifier lists must split the three classifiers. Every changed line must lie inside the
    block the stream test drives, in the row's functions. A line inserted after a function's
    closing `}` counts as top level, and `--self-test` checks that this case is refused.
  - `make ladder-stream-test` case X runs both versions per classifier. For each unaffected
    classifier, both must match:
    - the invocations (argv and the whole env, less PWD, SHLVL, `_` and OLDPWD);
    - the body's records around them (phase markers, lad-sample field set and rc, done records'
      rc, CRC/FAIL/NDONE).

    Invocations must differ for each affected classifier. X-mut shows that both comparisons
    resolve. The measurement code around the invocation is covered by this comparison and by
    review.
  - `make ladder-campaign-test`'s compat scenario covers the refusals: an affected classifier, an
    undeclared change, a change beyond the body, a `spec.json` that is not the recorded bytes, and
    a row that does not cover the run's classifier.
  - The first row (9126a6f) keeps upstream and ours-engine; ours-plain is affected.
  - CI checks out full history for case X.
- `make ladder-respec [COHORT=]` (`scripts/g3/ladder-respec.sh`) regenerates every committed ladder
  spec from its own PARAMS header and prints what changed beyond the body. All 18 c1 specs were
  regenerated after the fix below: body-only changes.
- The ladder rehearsal's **plain** check: an ours-plain case writes nothing under the cohort's
  rendezvous prefix, and counts no Rendezvous-PutObject. The containers already carried the
  node's cohort engine env, but no check could see ours-plain run the engine on the viral DB.
  `spec-o0-engenvmut` plants the leak back and must fail it.
- `make ladder-types [CHECK=1]` (`scripts/g3/ladder-types.sh`, `scripts/lib/ladder_types.py`)
  writes `scripts/g3/ladder.types.tsv` from truffle, recording the truffle version and the query.
  With CHECK=1 it compares the committed table with truffle's current answer. `make test` validates
  the table offline.
- **Review fixes to O3 right-sizing:**
  - `derived_host` is honoured only for `@floor:<predecessor>`, or for `@select:<self>` on an alias
    whose candidates all qualify. The reviewer's three probes are refused in the self-test.
  - O3's delta and lever rows state that they include the per-N host right-sizing (vCPUs, memory
    and network).
  - The quota wait clock excludes time spent on the campaign's own sibling runs, with a new test.
  - `permanent_quota` and the dead `ns` in `bracket()` are removed.
  - The self-test now asserts that O5 inherits the right-sized host.
  - A stale docs sentence is fixed.
- **O3 right-sized per N** (Scott, 2026-10-11, #25).
  - **The type:** each O3-n\<K\> and O3-cost-n\<K\> (`instance @floor:O2`, `@floor:O2-cost`) runs
    on the smallest non-metal type of O2's winning family that holds table/K by `fits()`. The types
    come from the new `scripts/g3/ladder.types.tsv` (truffle, 2026-10-11). At c1 this gives
    x8g.4xlarge at 8, x8g.2xlarge at 16 and 32, and r8g.4xlarge at 16, all tested.
  - **The one-lever check:** the host change is coupled to SHARDS as a derived move. It is declared
    in the `derived` column's `instance:` clause, and without that clause it is refused. The O3
    alias's own host is its winner's (`@select:O3`), so O4a and O5 inherit it.
  - **The bracket:** it predicts each N on its own type. Its grid is the candidates' N, {1, 2, 4,
    8, 16, 32}: 64 is dropped, with no O3-n64 added, and a grid with an N that no row has is
    refused.
  - **O2:** the rule text records Scott's ruling of one candidate per family.
- **Campaign quota refusals** (`ladder_campaign.py` `pick()`):
  - a request that exceeds the quota on its own is permanent: the rung stops at once and is
    reported, and the rest of its family carries on;
  - a refusal caused by running instances is waited for, at most `AK2_CAMPAIGN_QUOTA_MAX_WAIT_S`
    in total (default 6 h).

  Two new stub-test cases cover these.
- **`make ladder-select`:** the rule's candidates must be alias_of exactly, every rung and no
  other (N5).
- **`alias_cohorts` checks:**
  - `ladder_tables.py` verifies each pair with the generator's rule before reading the target's
    runs. A pair whose configurations differ is a DEFECT (levers), and one that cannot be verified
    is not read (N1);
  - `ladder_levers.py check [TSV] [--resolved RES]` verifies the declarations of any table it is
    given (N2).
- **Candidate rungs for every selection** (docs/ladder.md, "Candidate rungs"). S4, S8, O2,
  O2-cost, O3 and O3-cost are aliases over candidate rungs named `<rung>-<short value>`. Each
  candidate changes only its selecting rung's key-group, the predecessor counts as a candidate, and
  `not_run_cohorts` handles cohort-dependent sets. The candidates are:
  - `S4-t48` … `S4-t1` (P × T on x8g.24xlarge, P ≤ cohort);
  - `S8-k2` (the X quota holds 2 nodes);
  - `O2-r8g` and `O2-x8g`, and their `-cost` copies: one per family, its smallest type holding the
    table at N = 1;
  - `O3-n2` … `O3-n32`, and their `-cost` copies.

  O3's rule now selects by measured median (wall_s, or billed_usd for O3-cost) over candidates
  bracketed per cohort around fit R's prediction for O2's type. The bracket widens to every
  candidate where the prediction is not within data.

  `@select:<alias>[:KEY]` resolves any key to the winner's value. A winner that is not a candidate
  at the cohort is refused. The table goes from 36 to 62 rows.
- **`alias_cohorts`** (ladder.levers.tsv, ladder_levers.py, ladder_tables.py). At a cohort where a
  cost-chain rung's resolved configuration equals its time counterpart's, it is `alias: same
  configuration as <rung> at c<C>` and reads that rung's runs. At c1 this covers O0-cost → O0,
  O0b-cost → O0b and O2-cost-r8g → O2-r8g. The generator refuses an aliased rung, a declaration
  whose two rungs differ, and an undeclared coincidence. `make ladder-check` verifies the
  declarations against the committed `ladder.resolved.tsv`.
- **`not_run_cohorts` c1** for O1, O1-cost, O4b and O4b-cost. Each one's only c1 candidate is its
  predecessor's configuration.
- **c1 O-arm specs:** `runs/g3-l-o0-c1.json`, `runs/g3-l-o0b-c1.json` and `runs/g3-l-o2-r8g-c1.json`.
- **Review items from ladder-select:**
  - `parse_rule` refuses duplicate axis and ties clauses.
  - `ladder_levers` refuses a resolution whose note's rule sha256 no longer matches the rule text.
  - `ladder_tables.load_resolved` checks cites, and a row whose cites fail leaves the alias
    unresolved, with a note.
  - There is a stub test of the missing-summary-line refusal (`AK2_SELECT_TABLES` seam).
- **`make ladder-select` without `RUNG=`** writes every rule that selects and lists the others as
  `not selected`. With `RUNG=` it is all or nothing.

- Ladder selection (docs/ladder.md, "Selection"): `make ladder-select COHORT=<c> [RUNG=…]
  [DRY_RUN=1]` (`scripts/g3/ladder-select.sh`, `scripts/lib/ladder_select.py`), and its stub
  test `make ladder-select-test` (in `make test`).
  - **What it does.** It applies the registered `select` rules of `ladder.levers.tsv`, parsed from
    their text (candidates, axis, ties), to a fresh run of make g3-ladder's program. It writes the
    S\*-time and S\*-cost alias winners into `scripts/g3/ladder.resolved.tsv`.
  - **Refusals.** It refuses a candidate with n < 2, a Law 1 DEFECT, a g3-ladder run without its
    summary line, and stale citations.
  - **A row** cites a snapshot of the tables (`results/g3/ladder-select/c<C>-<fp>/`) and every
    candidate run's cohort.json and member manifests, each with its sha256 (new `cites` column).
    The `margin` column says whether the winner's margin over the runner-up is resolved under the
    tables' rule. A winner taken from an unresolvable margin is labelled "chosen by the
    registered rule from an unresolvable difference".
  - **Other rules.** It reports what each still needs:
    - S4 and S8 are not run at c1;
    - O2, O4b, and S4 and S8 above c1, have candidates that are configurations, not rungs;
    - O4b's only c1 candidate is O4a's own;
    - O3 is chosen by the #26 fit.

    A minimal mechanism is proposed: candidate rungs under an alias.
  - **Deterministic and idempotent.** A current row stands byte for byte, and no snapshot is made.
- `ladder_levers.py` reads `ladder.resolved.tsv` by its header's column names and checks every
  `cites` entry (`cites_ok`: a `results/` file that still hashes to its cited sha256), so a
  resolution whose evidence changed is refused (exit 3).
- `scripts/g3/ladder.resolved.tsv`, first rows (`make ladder-select COHORT=1`, from the c1
  campaign 20261011-072211; snapshot `results/g3/ladder-select/c1-027bc052f8fb/`):
  - c1 S\*-time → S9: median wall_s 474.0 s against Sstar-r8g's 477.5 s. The margin is 3.5 s
    against a 4.0 s threshold, so it is unresolvable (below instrument granularity) and labelled
    as such;
  - c1 S\*-cost → S9: median billed $1.2349 against $1.5002. The margin is $0.2653 against
    $0.0126, so it is resolved.
- The ladder campaign (docs/ladder.md, "The campaign"): `make ladder-campaign COHORT=<c> [REPS=2]
  [RUNGS=…] [CONCURRENCY=1] [FAMILY_LIMITS=X=2] [DRY_RUN=1]` (`scripts/g3/ladder-campaign.sh`,
  `scripts/lib/ladder_campaign.py`).
  - **The plan.** Every committed `runs/g3-l-*-c<c>.json`. Rep 1 is cheapest first: the
    measured median billed $ where a done run exists, else cost_limit × nodes. Ties go in ladder
    order, and rep 2 is reversed.
  - **Done runs are skipped.** A (rung, cohort, rep) is done when it has a run whose
    `spec_sha256` and params match the committed spec and whose record is clean:
    - members exit 0 and `own_gone`, `members done`, the prefix fetched;
    - no sweep or abort failures, the scoped orphan check 0;
    - kept in the attribution by ladder_tables, and not a recorded defect.

    A run without `params.rep` counts as rep 1, so S2a's `20261011-042400-f72142e-34a4-n1` is
    S2a rep 1.
  - **Launches.** Through `make run … NODES=<WANT_N>`, one launch at a time. One run is in
    flight by default (`CONCURRENCY=1`): concurrent runs share S3 and RODA, which would confound
    the timing comparisons. Above 1, a per-family limit (default 2) applies and the first launch
    runs alone. A rung's reps go in order, and quota_check decides (wait on 1, stop on 2).
  - **After each run:**
    - `make orphans` (informational while others are in flight, a hard stop with none);
    - `make g3-ladder OUT=…`, judged only by its summary line. A Law 1 DEFECT, or no summary
      line (a crash), stops the campaign;
    - the outcome, judged from the record rather than from make run's exit (including each
      member's AZ), with a row in `results/g3/ladder-campaign/<ts>.tsv`.
  - **Failures.** InsufficientInstanceCapacity gives a capacity row, appended to
    `g3_defects.tsv` when the campaign ends, and one retry in an AZ that
    `scripts/g3/ladder.azs.tsv` documents with a git-tracked manifest. Any other failure stops
    that rung.
  - **Resilience.** Drivers write to log files that the campaign follows, in their own sessions,
    so a killed campaign leaves them running. SIGHUP is left alone, for nohup and tmux. Nothing
    is committed.
  - Its stub test, `make ladder-campaign-test`, is in `make test`.
- `make g3-ladder OUT=<dir>`: the ladder tables written elsewhere than `results/g3/ladder/`.
- Launch overrides in run.sh and run-multi.sh (docs/run.md, "Launch overrides"):
  - `AK2_LADDER_REP=<n>` records `params.rep` and `rep_source` in every manifest and in
    cohort.json (`ladder_levers.py spec-params SPEC --rep n`). The spec stays byte-identical
    across reps.
  - `AK2_LAUNCH_AZ=<az>` launches in an AZ that `scripts/g3/ladder.azs.tsv` documents for the
    type, with its evidence checked: a git-tracked manifest of that type in that AZ
    (`ladder_levers.py az-alt`). It is recorded as `launch_override`.
  - Both are refused before anything is sent if invalid. `run_sh_test.sh` and
    `run_multi_test.sh` cover them.
  - run.sh checks the launched instance's AZ against the requested one (`AK2_LAUNCH_AZ`, else the
    spec's pinned AZ). On a mismatch it terminates the instance and exits 2.
- `AK2_QUOTA_FAMILY_ONLY=1 scripts/lib/quota_check.sh REGION TYPE 1`: the quota family alone,
  with no AWS call.

- The ladder rehearsal (#53; docs/ladder.md, "The rehearsal"): `make rehearse-ladder`, and
  `make rehearse SPEC=runs/g3-l-*` for one committed c1 spec, both after `make util-stream-test`
  (`scripts/lib/ladder_rehearse.sh`, `scripts/lib/ladder_rehearse_check.py`).
  - The ladder body runs end to end on AL2023 aarch64 containers (rootful podman: the VM's real
    `drop_caches`, tmpfs mounts with `huge=`, the THP knobs), under the preamble as `bash -e -c`.
    It clones and builds the committed tree on the node, and uses the viral database as RODA
    and real read sets.
  - It covers every arm:
    - upstream with serial and overlap uploads, 1 and 2 lanes;
    - ours-plain;
    - the engine at K = 2 and at N = 2 over TCP;
    - O5's sdk-stream emitter;
    - S5 with real rapidgzip 0.14.5 on an input with trailing bytes and on a corrupt one;
    - the negative tests;
    - phases and net accounting, including a slow SETUP=overlap build and tail uploads lagging
      the hashes;
    - the resolver;
    - every committed c1 spec, then `ladder_tables.py` on their record (0 DEFECTs, aliases
      read as their winners);
    - a TTL kill (KILL and TERM) mid-classify.
  - Every on-node sha256 is checked against upstream at the pin. The Law 1, S5 fallback,
    net-accounting, TTL and tables checks each fail under a planted defect.
- A pre-launch probe of the classic `aws s3 cp` rate (docs/probes.md, probe f):
  `runs/g3-probe-awscp-r8gd.48xlarge.json` (`scripts/g3/probe-awscp.body.sh`; TTL 40 min,
  cost_limit $9.41).
  - It stages hash.k2d onto r8gd.48xlarge's single NVMe device exactly as S0's fetch-db does
    (`lv_nvme single`, lv_stage_db awscp-default's client and command line), for 20 min or
    300 GiB.
  - It streams `probe-awscp` progress every 10 s and records the resolved client. The tables
    are `probe_tables.py awscp` (post script).
  - Rehearsed with `probe_rehearse.sh` (kind awscp: stopped by bytes, by time, and complete);
    DRY_RUN passes. Not launched.

### Fixed

- **The ladder tables re-raised recorded defects.** A run listed in `scripts/lib/g3_defects.tsv`
  (capacity refusals, failed launches) is now reported once, as `recorded defect (<class>):
  excluded`, and its contract and incomplete checks are no longer DEFECTs. They do not count toward
  the DEFECT total or the exit code.
  - Its other checks, and Law 1, are never suppressed.
  - A run recorded as `capacity` that has any sample record is not a refused launch. Nothing is
    suppressed for it, and a `DEFECT (recorded)` names the mismatch.
  - On this branch's record: 41 DEFECT lines from 13 recorded runs before, 0 after.
  - Test: `ladder_tables_test` `recorded_defects`.
- **A conditional `alias_cohorts` entry whose target is no candidate there** (the reviewer's latent
  gap). Before, it read the target's runs, which do not exist, wherever the two configurations
  coincided. It is now `own` where the target is not run at the cohort, or is outside its alias's
  bracket, range or candidates (`candidate_out`). Self-test cases cover O3-cost-n2, O3-cost-n4 (the
  bracket) and O4b-cost-if8 (the range).
- **Absolute THREADS on the O arm.** S4's T = 16 ran 16 threads per sample on x8g.2xlarge's 8 vCPUs,
  and O4b's range collapsed to 1 on every type below 32 vCPUs. The thread ratio above replaces it.
- `ladder_campaign.py` `record_problems`: a cohort member that never launched (capacity) has no AZ; the AZ check now names it as "none" instead of crashing on `sorted()` of None and a string (the c10 S9 rep 2 retry, campaign 20261013-183231, crashed this way). Regression case in `ladder_campaign_test`.

- **Ladder ours-plain ran the engine** (scripts/g3/ladder.body.sh `lad_one`). The cohort env that
  `make run` gives every node (`AK2_ENGINE_N`, `_RANK`, `_RENDEZVOUS`) reached ours' plain path,
  and ours takes the engine path whenever `AK2_ENGINE_N` is set. The engine's shards are resident
  and it ignores `--memory-mapping`. So O0 at c1 (843e958, x8g.24xlarge) read an anonymous copy
  of RODA v205's 1.1 TB table on top of the same table in tmpfs:
  - memory in use rose about 58 GiB/s on 8 read streams to a peak of 1466 GiB;
  - the run was OOM-killed (rc 137) before "done.";
  - upstream's S9 on the same configuration peaked at 1125 GiB.

  `lad_one` now strips `AK2_ENGINE_*`, `AK2_COHORT` and `AK2_COHORT_CHECK` from ours-plain's
  environment. `make ladder-stream-test` case P checks this by behaviour, and P-mut restores the
  leak and must fail. Ours' `-M` itself was not at fault. On the viral DB on a tmpfs, peak
  RssAnon over upstream's `-M` is 52.0 to 65.6 MiB at 8, 32 and 96 threads, not growing with
  threads. The table's RssShmem is the same for both. Under the leaked engine env, ours `-M` holds
  1.8 GiB anonymous and no shmem. Source: results/g1/mmap-rss-20261012-9911a93/ (manifest.json,
  peaks.tsv). The new `chash.Table.Mapped` reports Mmap's mapping.
  `TestMmapSharedReadOnly` asserts that the mapping is shared, read-only and never a copy: the
  cells alias the mapping, a write faults, and on Linux smaps shows `ms`, no `wr`/`mw` and 0 kB
  anonymous after a full scan, with Load as the negative control.
  `TestMemoryMappingIndex` asserts which path `-M` selects.
- `run-multi.sh`: the cohort's exit and `orphans_rc` came from the global orphan check, which
  fails whenever any other ak2 instance is alive. A cohort that ran beside another run therefore
  exited 3. Each member's scoped check (`orphans.sh --own`) now decides
  (`orphans_scope: "own"`). The global check is kept as `orphans_global_rc`, for information.
  The finish ignores SIGPIPE, so a reader that has gone cannot stop cohort.json being written.
- `ladder_tables.py` read run dirs only under `results/<gate>/2026*`. It now reads any
  `<yyyymmdd>-*` run id.
- Found by the ladder rehearsal (#53):
  - `ladder_tables.py`: a compound lever phase (`run:A+run:B`, as `ladder.levers.tsv` writes
    it) was read as missing, because only the first term's scope was stripped. Each term now has
    its own scope. A run's own lever phase that matches nothing is a DEFECT (contract), not a
    silently missing value. Unit tests are in `ladder_tables_test.py`.
  - The ladder body's S5 identity rule (Scott, 2026-10-11): GNU gzip's exit 2 is a warning (for
    example "trailing garbage ignored": the output is complete, and upstream's wrapper ignores the
    status). It is recorded as `gz_warning` (identity line and `s5`) and is neither a difference
    nor an input defect. An input defect is a gzip exit other than 0 or 2, or an empty stream. Any
    non-zero rapidgzip exit still differs. The tables' B1 rule and `input` DEFECT follow. The
    rehearsal case `s5-garbage` and a ladder-stream-test case cover it. The 15 c1 specs are
    regenerated with the body.
  - `ladder_tables.py` (#53 review):
    - A successor's lever phase term missing on its predecessor run is a DEFECT (contract) when
      the body marks it on every run, and a note only for identity, build-wait and sha-get.
    - `gz_warning` is named per sample in tidy.tsv (`s5.gz_warning`) and in a summary.md note.
  - The rehearsal's tail check has its own id, `tail-resolve`. A negative control of `tail`
    counts only if `tail-resolve` passes on the same run, and an unresolved try is a RETRY row.
    The rehearsal log records each spec's sha256.
  - The ladder body's `lad_crit` on the engine path: the engine's exit time is recorded as the
    engine exits (`eng.end`, from `lad_engine`'s subshell). Previously a hash made after the exit,
    but before the watch loop noticed, counted as covered.

- The #25 ladder body, lever table and generator (#51, WP-7; docs/ladder.md).
  - `scripts/g3/ladder.body.sh`: one body for both arms of both ladders. The lever choices are
    a PARAMS block in the payload. The phases are the same on both arms, every run is cold
    (`drop_caches` first and before load), and the ETag is checked on every arm. Each
    classified sample streams a `lad-sample` line (#52's contract v1) and is appended to
    `out/lad-samples.jsonl`, with the on-node sha256 of every output. S5 adds an identity
    phase and falls back to GNU gzip per sample where rapidgzip differs.
  - `scripts/g3/ladder.levers.tsv`: every rung of both ladders, with #52's columns plus
    `status`, `group` and `coupled`.
    - S2b, S7 and O4 are split. S2c (the inputs onto tmpfs, on r8gd.48xlarge) now comes before
      S2a, so S2a changes only the host.
    - Ladder 2 runs twice (Scott, 2026-10-10): O0 … O5 from S\*-time and O0-cost … O5-cost from
      S\*-cost, each with its own selections. O5 is O\*-time and O5-cost is O\*-cost.
    - S3 is not run, because the tune probe chose `none`.
  - `scripts/g3/mkspec-ladder.sh` (`make ladder-spec`) writes `runs/g3-l-<rung>-c<cohort>.json`
    deterministically. It refuses any rung with an unresolved placeholder.
  - `scripts/lib/ladder_levers.py` (`make ladder-check`, in `make test`) checks that each rung
    changes exactly one key-group.
  - `scripts/tests/ladder_stream_test.sh` (`make ladder-stream-test`, in `make test`) checks the
    body's streaming, phase boundaries, serial vs overlap uploads, the engine path and the S5
    fallback by behaviour.
  - `scripts/tests/ladder_levers_tables_test.py` (in `make test`) runs the real lever table
    through #52's `ladder_tables.py`. On a synthetic record, both S\* vs O\* pairs follow their own
    chain with 8 resolved lever rows each.
  - The seven rungs fully determined at c1 are committed (S0-T1, S0-Tv, S1, S2b-i, S2b-ii, S2c,
    S2a), and all pass `DRY_RUN=1`. Each spec's header gives its TTL and notes that the classic
    `aws s3 cp` rate is unmeasured.
  - `rapidgzip-Pauto` is a registered rule (accepted 2026-10-10): k = clamp(floor(nproc ÷
    (2 × samples at once)), 1, 16) threads per mate.
  - The #51 review fixes:
    - The S5 identity phase records each tool's real exit status (B1). A non-zero exit or an
      empty output now differs and falls back to gzip, and the stream test covers a failing tool.
    - The measurement-only phases have distinct names (`identity`, `sha-get`, `sha`,
      `sha-critical`), so deltas can be reported gross and net (Scott, 2026-10-10).
    - S2d (huge=always) comes before S2c, and S2b-ii's tmpfs is huge=never (NB7).
      `upstream-cohort.sh mount` takes an optional HUGE argument.
    - The S\* endpoints are aliases of the selected candidate's runs, and S\*-cost and O\*-cost
      are chosen by lowest median billed $.
    - Every selection has a registered rule (`select` column, NB4).
    - A resolution must cite a `results/` run dir, and the one-lever check runs again on the
      resolved values (NB3).
    - Derived values: `vcpus/<k>` ratios, a `derived` column, and the values used in `lad-config`
      (NB1).
    - Engine runs check completeness of the home samples (NB5), and `needs` must agree with the
      placement (NB6).
    - O5 streams each lad-sample as its GETs finish (NB8).
    - The run order is documented (NB9). The input sha256 is not separated, and the reason is
      recorded (NB10).
  - The #51 re-review fixes:
    - B2: under SETUP=overlap the build is waited for in its own `build-wait` phase (not
      measurement-only), before identity, and its end is recorded.
    - `sha-critical` is decided by interval overlap with the node's classify spans.
    - Each node writes one `lad-net` line (`out/lad-net.jsonl`) with the seconds the net rule
      subtracts. Net wall = max over nodes (node end − critical_measurement_s) − first launch.
    - T1: the identity case runs with pipefail off, as on the node, and a mutation restoring B1's
      bug must fail it.
    - NB3: the one-lever re-check compares THREADS, PROCS and INFLIGHT as numbers at each rung's
      host. A `not_run_cohorts` column marks S4 and S8 not run at c1, where their only candidate
      is the predecessor's configuration.
    - An alias winner must be one of `alias_of`. GNU gzip failing in the identity phase is flagged
      `input_defect` (an input or staging DEFECT, not an S5 finding).
    - S5, S6, S7a, S7b, S9, Sstar-r8g and Sstar-r8gd are now determined at c1, so 15 c1 specs
      are committed.
  - The #51 third-review fixes:
    - `sha-critical` also counts done and in-flight uploads as covering spans (NB1).
    - The net rule is exact for one lane, O5 and the engine at N = 1. It is an upper bound for the
      engine at N > 1 and for several serial lanes.
    - A bad resolution (such as an alias winner outside `alias_of`) is a clean refusal, and a
      resolution row for a not-run cohort draws a warning.
    - The tables cross-check uses real alias rows and native not-run handling, with no stand-ins.
  - `run.sh` and `run-multi.sh` record a ladder spec's PARAMS as `manifest.json` and
    `cohort.json` `params`.
  - `results/g3/ladder-modelled.tsv` holds the header only.

- Ladder tables:
  - `not_run_cohorts` in ladder.levers.tsv: at the cohorts it lists, a rung is skipped like
    `status: not-run`, and its successor's delta is taken against the nearest ancestor that ran.
  - The body's identity line (`lad-identity`, `input_defect: true`) raises an input DEFECT
    where the sample's own `s5` does not already show one.
  - `lad-net`'s components `identity_s`, `sha_get_s` and `sha_critical_s` are accepted,
    shown, and must sum to `critical_measurement_s` within 1 ms.
- Ladder tables, gross and net (Scott's ruling, 2026-10-10, #25). Every wall delta and pair is
  reported both ways, with net as the headline:
  - net wall is computed per node: the max over nodes of (`terminated_at` −
    `critical_measurement_s`), minus the first launch. Each node's number comes from its one
    `lad-net {v, rank, critical_measurement_s}` line in `out/lad-net.jsonl`, which #51 computes
    under its final rule. A missing line makes net missing (with a note). A malformed one, or a
    `critical_measurement_s` beyond the node's own window, is a contract DEFECT;
  - net billed and net effective cost are prorated, labelled "net (prorated)";
  - each series gets its own resolution check.

  Alias rungs (`status: alias: …` with `alias_of`) read their winner's runs from
  `scripts/g3/ladder.resolved.tsv` (key `alias`). An unresolved alias says "alias unresolved".
  The s5 contract follows the body's B1 rule: `differs` also covers a non-zero `gz_exit`/`rg_exit`
  or an empty-stream sha256, and `identical` is refused with any non-zero exit. A gzip failure
  (a non-zero `gz_exit` or an empty gzip stream) is an input DEFECT of its own. A resolved winner
  outside `alias_of`, or a duplicate (rung, cohort) row, is a DEFECT. The net model scales the
  in-sample measurement (sha-critical, s5-identity) by P_target/P (docs/ladder.md, "Ladder
  tables").
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
    T1 from the c10 S0-T1 records' per-thread rate, gross and net (net from each run's net wall
    by the same formula, billed prorated). The per-sample span is the union of the
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

- `ladder_tables.py`'s successor-phase contract check skips successors that are not run at the
  run's cohort. The c1 record's DEFECTs on the refused S2a launch drop from 5 to 3.
- The rehearsal's resolver case uses the alias model (S4 → S4-t12 at c10).

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
- `scripts/run.sh` ran util.py before the spec's post script and the `.orphan_check` write,
  both of which can change the manifest. So `tables/util.json` recorded the sha256 of a manifest
  that no longer existed (found on 20261009-223514-4ee77c3, #58). util.py now runs after the
  last manifest write. `make test` runs `scripts/lib/util_order_test.py`, which checks that
  order statically in run.sh, refinalise.sh and run-multi.sh, and checks that no cohort post
  script writes a manifest or cohort.json. refinalise.sh and run-multi.sh already had the right
  order.
- `scripts/refinalise.sh` on a cohort member changed the member's manifest but left the cohort's
  `tables/util.json` citing the old one (#58). It now re-derives the cohort dir's
  `tables/util.tsv` too. `scripts/lib/cohort_dir.sh` finds the cohort dir from the manifest's
  `.cohort.dir` or `.cohort.id`, or from a `<cohort>-r<k>` run id, and only when its cohort.json
  lists the run. A member whose cohort has no cohort.json is reported instead.
  `util_order_test.py` checks the order and runs cohort_dir.sh on scratch run dirs.
- util.py's fleet coverage calls a counter with only a start or only an end value "unpaired",
  not "missing" (#58).

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
