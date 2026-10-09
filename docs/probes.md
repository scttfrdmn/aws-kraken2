# G3 probes: upstream's staging, S3 contention and decompression (#25)

Three cheap AWS probes and one local benchmark measure the inputs that the upstream arms of
`make g3-frontier` would otherwise assume. Scott approved them on 2026-10-08 in place of the
validation run.

| probe | spec / script | node | what it measures |
|---|---|---|---|
| (c) decompression | `runs/g3-probe-decomp-c8g.4xlarge.json` (`scripts/g3/probe-decomp.body.sh`) | 1 × c8g.4xlarge | gzip, pigz -p 16, igzip, rapidgzip -P 16/-P 8 on SRR5935773, sequential and concurrent mates, output identity against gzip -dc |
| (a) staging | `runs/g3-probe-stage-x8g.24xlarge.json` (`scripts/g3/probe-stage.body.sh`) | 1 × x8g.24xlarge | RODA hash.k2d onto tmpfs: rget sweep, whole-object rget and s5cmd writes, each ETag check timed separately, an aws s3 cp (CRT) rate sample |
| (b) contention | `runs/g3-probe-cont-c8gn.4xlarge.json` (`scripts/g3/probe-cont.body.sh`) | 64 × c8gn.4xlarge, one cohort | concurrent ranged GETs of hash.k2d to /dev/null at N = 1, 16, 32, 64, 60 s each |
| (d) #44 fix speed | `scripts/g3/hitbench.sh [PRE] [POST]` | local | our classifier before the fix (3201a75) and after, SRR062634 8M pairs against Standard-8, warm, alternating |

## Running them

Run them cheapest first. Rehearse each one, then launch it from a pushed commit. Check for
orphans after each run.

```bash
make rehearse SPEC=runs/g3-probe-decomp-c8g.4xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-decomp-c8g.4xlarge.json
make rehearse SPEC=runs/g3-probe-stage-x8g.24xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-stage-x8g.24xlarge.json
make rehearse SPEC=runs/g3-probe-cont-c8gn.4xlarge.json
make run GATE=g3 SPEC=runs/g3-probe-cont-c8gn.4xlarge.json NODES=64
make orphans
scripts/g3/hitbench.sh 3201a75 HEAD
make g3-frontier
```

- **Specs** come from `scripts/g3/mkspec-u.sh probe-<kind> <type> <TTL min> <body> us-west-2b`.
- **Rehearsal:** `scripts/lib/probe_rehearse.sh` runs each body unmodified against local
  stand-ins:
  - S3 is replaced by the stub aws;
  - hash.k2d is replaced by a 320 MiB random file with a real multipart ETag, served with Range
    and If-Match by `k2probe serve-file`;
  - s5cmd is replaced by a stub;
  - the contention probe runs as three concurrent members.
  It passes on observed output: streamed lines equal pushed lines, and the counts and identity
  assertions in the script's header hold.
- **Tables:** the post scripts run `scripts/lib/probe_tables.py`, writing
  `tables/probe-{decomp,decomp-conc,staging,contention,contention-nodes}.tsv`.

## How the frontier uses them

`scripts/lib/g3_frontier.py` reads every `results/g3/*/tables/probe-*.tsv` and adds labelled
upstream variants. The measured single-node and single-rate points stay alongside them.

- **Staging at probe (a)'s rate:** the fastest complete write whose ETag check passed.
- **Staging capped by contention:** probe (a)'s rate × f(N), where f(N) is the slowest node's
  rate at N divided by a lone node's rate, from probe (b).
- **Decompression options:**
  - each identical tool's time relative to pigz, both run sequentially as U1's preparation was;
  - decompression pipelined ahead of classify;
  - gz streamed through the wrapper's pipes, using the tool's concurrent-mates time.

**Hygiene:**
- Neither (c) nor (a) reads from storage: (c)'s inputs sit on /dev/shm and (a) writes to tmpfs,
  so `drop_caches` does not apply.
- (b) synchronises its stages from the members' clocks via rendezvous records in the cohort prefix.
