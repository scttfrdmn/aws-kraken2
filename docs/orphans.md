# make orphans

**What:** lists every instance this repo launched that is still alive (`pending`, `running`,
`shutting-down`, `stopping` or `stopped`) in **every region enabled in the account**, as listed by
`aws ec2 describe-regions`.
- It queries all regions in parallel, about 3 s for 18. It sweeps all of them because spawn has
  placed runs in an unasked-for region before.
- An instance counts as ours if it is tagged `ak2:project=aws-kraken2` (added by `run.sh` after
  launch) or `spawn:task-id=ak2-*` (set by spawn at launch, so this also catches an instance whose
  `create-tags` never happened).
- **An instance with neither tag is invisible to this check.** Both tags are set at or right after
  launch, and the scoped check also matches this run's instance id. But an instance launched
  outside `make run`, or one whose tags were removed, will not be found.
- Backed by `scripts/orphans.sh`.

**It is global and strict:** every live ak2 instance counts, including other agents' runs that
are still in flight. **Run it when no runs are in flight**, e.g. at the end of a session, or
after every concurrent `make run` has finished.

**`make run`'s own check is scoped** (`scripts/orphans.sh --own <task_id> <instance_id>`, run
after every run; nf-spawn#96):
- It fails (exit 1) only if *this run's* instance, matched by instance id or by
  `spawn:task-id`, is still alive.
- Other live ak2 instances are listed as "informational, not this run's", with task id, launch
  time and TTL, and do not fail it.
- It exits 2 if any region could not be queried, because then the run's own instance cannot be
  confirmed gone.
- `run.sh` saves the check's output as `<run dir>/orphans.txt`. It also records the outcome in
  the manifest as `.orphan_check`, which `make report` shows as a row:
  `{mode:"own", task_id, rc, own_gone, others:[{region,id,task_id,state,launch,ttl_deadline,flag}], checked_regions, failed_regions, at}`.
  `flag` is one of `within_ttl`, `probable_orphan`, `deadline_unparseable` or `no_deadline`.
  The summary is written by `orphans.sh` itself on every exit, when `AK2_ORPHANS_JSON=<file>` is
  set.

**Probable orphans (both modes):** an instance more than 15 minutes past its
`spawn:ttl-deadline` tag is flagged `PROBABLE ORPHAN`, since spored terminates a healthy run at
its TTL. In the scoped check this is reported, not failed. Follow it up with `make orphans` once
nothing is in flight. A `spawn:ttl-deadline` that does not parse (empty, malformed, or not in
UTC) keeps the row and flags it `deadline unparseable (…)`. Such an instance is never dropped:
dropping it would make the check fail open.

**Inputs:** `AWS_PROFILE` (default `aws`); `AK2_TAG_PROJECT` and `AK2_TASK_PREFIX` from
`scripts/ak2.env`.

**Outputs:** one line per live instance:
`region  instance-id  state  type  launch-time  task-id  ttl=<ttl>  within TTL | PROBABLE ORPHAN …`.
Otherwise `orphans: none in <N> regions`, or in scoped mode
`orphans: this run's instance(s) and task <id> are gone (<N> regions checked)`.

**Exit:**
- Global mode: 0 if none; 1 if any are alive; 2 if describe-regions or any region's query failed.
  Treat 2 as "unknown", not as clean.
- Scoped mode: 0 if this run's instance is gone; 1 if it is alive; 2 if a region failed.
- Both modes exit 2 if any jq stage fails (e.g. malformed describe-instances output) and on
  `--own` with no task id.

**Failure looks like:** exit 1 with rows listed. For each row, check whether a `make run` is still
in progress, by looking at its run dir for a missing `manifest_finalised_at` or at the task id's
gate and run id.
- If none is in progress, terminate the instance with
  `aws ec2 terminate-instances --region <r> --instance-ids <id>`, then run `make orphans` again
  until it exits 0. Record the stray instance's cost against the run that left it.
- A `shutting-down` row a minute after a run is normal; re-run before acting.
- A row inside its TTL usually belongs to a concurrent run; leave it alone.
