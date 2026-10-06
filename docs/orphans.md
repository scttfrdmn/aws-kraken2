# make orphans

**What:** lists every instance this repo launched that is still alive (`pending`, `running`,
`shutting-down`, `stopping` or `stopped`) in **every region enabled in the account**, as listed by
`aws ec2 describe-regions`. It queries all regions in parallel, about 3 s for 18. It sweeps all of them because spawn has
placed runs in an unasked-for region before. An instance counts as ours if it is tagged
`ak2:project=aws-kraken2` (added by `run.sh` after launch) or `spawn:task-id=ak2-*` (set by spawn
at launch, so it also catches an instance whose `create-tags` never happened). Backed by
`scripts/orphans.sh`. `make run` calls it after every run (nf-spawn#96).

**Inputs:** `AWS_PROFILE` (default `aws`); `AK2_TAG_PROJECT` and `AK2_TASK_PREFIX` from
`scripts/ak2.env`.

**Outputs:** one line per live instance on stdout:
`region  instance-id  state  type  launch-time  task-id`. Otherwise
`orphans: none in <N> regions`.

**Exit:** 0 if there are none; 1 if any are alive; 2 if describe-regions or any region's query failed
(treat that as "unknown", not as clean).

**Failure looks like:** exit 1 with rows listed. For each row, check whether a `make run` is still
in progress (look at its run dir for a missing `manifest_finalised_at`). If none is, terminate it:
`aws ec2 terminate-instances --region <r> --instance-ids <id>`, then run `make orphans` again
until it exits 0. Record the stray instance's cost against the run that left it. A
`shutting-down` row a minute after a run is normal; re-run before acting.
