# Utilisation: make util-stream-test, make util, make util-backfill, make instance-types

**What:** every AWS run, on both arms, records how much of the machine it used over the billed
window (Scott's definition on #25, 2026-10-09). The definition, the sampler and what `make run`
does with it are in [run.md](run.md), "Utilisation". This runbook covers the four targets.

| target | does | cost |
|---|---|---|
| `make util-stream-test [N=3]` | checks that the sampler streams on every node (AL2023 under podman) | $0, local |
| `make util DIR=results/<gate>/<run>` | (re)writes `tables/util.tsv` for a run dir or a cohort dir | $0, local |
| `make util-backfill` | lower-bound utilisation of the existing `results/g3` runs | $0, reads `results/` |
| `make instance-types` | records vCPUs, MiB and line rates for every instance type in `results/` | $0, one read-only EC2 call |

## make util-stream-test [N=3]

`scripts/lib/util_stream_test.sh`. `make rehearse` runs it first, for every spec, with the same
N, and fails if it fails. It needs podman, with a podman machine that shares `$HOME`, and the
image `public.ecr.aws/amazonlinux/amazonlinux:2023`.

It starts N containers at once. Each one runs exactly what `run.sh` launches:
- the stub as `scripts/lib/mkstub.sh` builds it, as `bash -c`, which starts the sampler and
  execs the payload;
- the payload: `scripts/preamble.sh` plus a short body.

The stand-ins are only at the edges:
- `curl` answers IMDS, the bucket-region HEAD and the payload GET;
- `aws s3 cp` copies into a shared directory, and keeps every upload as its own timestamped
  version, so the test can see what was pushed and when;
- `sudo` runs the command.

The body runs three phases, each a known effect the sampler must resolve:
- **burn**: 8 s of one busy vCPU;
- **shm**: 256 MiB written to `/dev/shm` (tmpfs counts as used memory), held for 6 s;
- **net**: 64 MiB downloaded over the container's `eth0` from a server on the host;
- **hold**: 50 s of sleep, so the 30 s re-upload happens twice during the run.

It passes only if every node shows all of the following, read from the uploads:
- The container exits 0.
- `log/util.tsv` was uploaded at least twice before the body's `end` phase, and each upload has
  more ticks than the one before. So it streamed, rather than arriving only at exit.
- In the last upload:
  - the first tick is phase `stub` and precedes the preamble, so the stub started the sampler;
  - the last tick is the `final` one, at or after `end`;
  - no gap between ticks is longer than 2.5 s;
  - the phases stub, preamble, body, burn, shm, net, hold and end all appear.
- `scripts/lib/util.py` on the result finds all three effects:
  - burn: busy vCPU-s ≥ 0.8 × its seconds;
  - shm: peak used ≥ the phase's first tick + 200 MiB, and Shmem up by ≥ 250 MiB;
  - net: at least 64 MiB.

It also passes only if:
- no stretch of the run longer than 36 s went without an upload of `util.tsv`, which bounds
  what a TTL kill loses (the pusher re-uploads it every 30 s; the body holds 50 s to cover two
  pushes);
- a sampler whose stub exits before exec (exit 97) stops with it;
- a `once` tick after a loop that found no default route looks the interface up again.

**Overhead.** It prints two costs per node:
- the sampler's own CPU per tick: 0.5–2.4 ms here, at most 0.24% of one vCPU;
- the pusher's uploads, by object (in 65 s: `run.log` ×13, `requests.tsv` ×13, `util.tsv` ×3).
  Here `aws` is a stub. On an instance each upload is an `aws s3 cp` (a Python CLI process),
  which costs far more than the sampler. That cost is still to be measured on the first
  instance run: the task cgroup's CPU over an idle phase, from `tables/util.tsv`.

**Negative controls.** Each of these must FAIL:
- `BREAK=nopush` removes the pusher's `util.tsv` push, so the record reaches S3 only at exit;
- `BREAK=nostub` removes the stub's sampler start, so the preamble's fallback starts it late.

Run both after any change to the sampler, the stub, the preamble's pusher or the test itself:

```bash
BREAK=nopush scripts/lib/util_stream_test.sh 1   # must FAIL: uploaded 0 times before end
BREAK=nostub scripts/lib/util_stream_test.sh 1   # must FAIL: first tick is not the stub's
```

**Record:** `results/rehearse/util-stream-<UTC>-<commit>.log`. `KEEP=1` keeps the work dir.

**Limits.** The containers share the podman VM's kernel. So the node-level utilisations the
test prints are diluted by the VM's whole uptime (its `btime` is days old), and other
containers' work shows in `/proc/stat`. The phase checks use deltas and boundary ticks, so they
are not affected. `ethtool` is absent from the image, so the `E` records say `no-ethtool`. On
AL2023 instances, the ENA counters come from `ethtool -S`.

## make util DIR=…

`python3 scripts/lib/util.py DIR`, run on one of:
- a run dir (`manifest.json` + `log/util.tsv`): writes node, fleet and node-phase rows;
- a cohort dir (`cohort.json`): writes one node row per member, the fleet row and fleet-phase
  rows.

`run.sh`, `run-multi.sh`, `refinalise.sh` and `make report` call it themselves. A run without
`log/util.tsv` gets rows that say so in `coverage`. It also writes `tables/util.json` beside the
table, with util.py's commit and every input file with its sha256.

What is counted: only the default-route interface, and only NetworkCards[0]'s line rates.
Instances with more than one network card or ENI are undercounted. `make test` runs `scripts/lib/util_test.py`,
which checks every column against synthetic counters worked out by hand.

## make util-backfill

`scripts/lib/util_backfill.py`. It covers every run under `results/g2` (the Law 2 baselines and
loadbench) and `results/g3`, as node rows, plus every cohort, as fleet rows. For each, it derives
what the run's own files recorded.
- **Every U is a lower bound:** whatever was not recorded counts as 0.
- A resource with no record is `missing`; nothing is imputed.
- A fleet row takes only the members with capacity and a billed window, in numerators and
  denominators alike; the others are excluded and named.

**Rows cannot be compared across arms or run types.** Their CPU sources differ: the engine's
whole process, upstream's per-run getrusage, loadbench's per-run getrusage, or nothing. So a
higher lower bound does not mean higher use. The `arm` column says which arm or arms a row's CPU
came from: `ours`, `upstream`, `both` or `unknown`. `cpu_s_ours` and `cpu_s_upstream` hold the
two parts.

| resource | ours | upstream |
|---|---|---|
| CPU | the engine's getrusage over its whole process: user_s + sys_s of the `ak2-timing total` lines (`AK2_TIMINGS=1`) in `log/run.log`, else in `out/**/eng-*.stderr`; loadbench's `runs.tsv` rows with impl ≠ upstream | user_s + sys_s of every `kind: run` row with getrusage in the G2 runner's `runs.jsonl` (G2, U2); loadbench's `runs.tsv` rows with impl = upstream |
| memory | `ak2-engine mem` samples (every 15 s while an engine runs): the time integral of rss_kib between the first and last sample of each invocation (`U_mem_mean_lb`); the peak is the largest hwm_kib (`U_mem_peak_lb`). The engine's table is anonymous heap, so its RSS is used memory | none toward U_mem. The largest getrusage maxrss is reported as `rss_peak_gib`, a process RSS, not a lower bound of U_mem: under mmap it is file-backed page cache, which the kernel can reclaim |
| network | the bytes the logs state were moved: engine shard-load bytes and multipart part_bytes; `ak2_stage` and scripted-stager lines; the campaign's `inputs staged and verified: … GB` (minus half its last digit); stage-cohort's downloads (counted once); the probes' progress records | the same staging lines |

The engine's node-to-node routing has no byte count, so it is not included.

Some run types recorded no CPU and no memory at all: U1, diag44, the probes, stage-cohort, the
G2 smoke runs, and std8/roda-n8 memory. Their columns are empty, and `*_coverage` says `missing`.

`U_net_baseline_lb` can exceed 1: an instance may burst above its baseline rate up to the peak
rate (roda-n8 loaded its shard twice at about 14.6 Gbit/s on a 7.5/15 Gbit/s x8g.4xlarge).

**Outputs:**
- `results/util-backfill/util-backfill.tsv`, with columns gate, scope, run, spec, type, arm,
  nodes, billed_s, capacity, `cpu_s_*`, the `*_lb` utilisations, `rss_peak_gib`, the `x_*_ub`
  multipliers (upper bounds, because the U values are lower bounds), and `cpu_coverage`,
  `mem_coverage`, `net_coverage`, `coverage`;
- `results/util-backfill/manifest.json`, with the commit, the generation time, the caveats above
  and the instance-types file it used.

## make instance-types

`scripts/instance-types.sh`. It runs one `aws ec2 describe-instance-types` call for every type
named by a manifest under `results/`. It writes `results/instance-types/<region>.json`, which
holds vCPUs, MemoryInfo.SizeInMiB, NetworkPerformance, and NetworkCards[0]'s
BaselineBandwidthInGbps and PeakBandwidthInGbps, plus the query time. `util.py` and the backfill
use this file only when a manifest has no `instance.type_info`. `run.sh` records
`instance.type_info` at launch.

## Failure looks like

- `util-stream-test: rK FAIL …` names the property that failed on node K. Re-run with `KEEP=1`
  and look at `<work>/bucket/.v/…/log/util.tsv.*`, which holds every upload.
- `need podman`: install podman, or start the machine with `podman machine start`.
- `util.py: … has neither manifest.json nor cohort.json`: the wrong directory was given.
- In `tables/util.tsv`, a coverage of `no log/util.tsv` means one of two things: the run
  predates the sampler, or the stub never ran. For the second, see
  `spawn/<task_id>/command.log`.
