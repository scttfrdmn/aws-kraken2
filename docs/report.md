# make report GATE=… RUN=…

**What:** renders a markdown issue comment for one run from `results/<gate>/<run-id>/` and
nothing else. It accepts no other arguments, so a typed-in number cannot reach the report. Backed
by `scripts/report.sh`.

```bash
make -s report GATE=g0a RUN=<run-id> > /tmp/comment.md
```

**Inputs:** `results/<gate>/<run>/manifest.json`, which must be finalised
(`manifest_finalised_at` set). Also, if present: `decoded/*.json` (flat objects, rendered as
field/value tables) and `tables/*.tsv` (header row + data, rendered as markdown tables, first 60
rows). Derived files come from the spec's `runs/<name>.post.sh`. To add a number to a report, add
it to one of these files from a script, never to the comment.

**Outputs:** markdown on stdout, in this order: the run table (commit, pin, spec hash, instance,
AMI, region/AZ, truffle price, start/stop, billed seconds, cost and its basis, TTL/cost_limit,
task state, shell flags, preflight region, accessions, tool versions), Payer per bucket (seen
from the launch host and from the instance), datasets (ETag/VersionId at launch), each decoded
JSON, each table, then a collapsed list of every file with its size and sha256 prefix. Posting
the comment is the coordinator's job.

**Failure looks like:** exit 2 with `make report: …`, meaning the run dir or manifest is missing,
the manifest is invalid JSON, or it was never finalised (the run is in progress or aborted). A
`—` cell means the manifest lacks that field; fix the harness, not the comment.
