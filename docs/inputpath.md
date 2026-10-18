# The input-path sweep (I0–I4, #90)

## Records and report

**What:** `make inputpath-report RUN=results/inputpath/<run-id> [OUT=…]` renders the sweep's
report from one run dir and nothing else. Backed by `scripts/lib/inputpath_report.py` (python3,
stdlib only). Test: `make inputpath-report-test` (in `make test`), on the synthetic run dir
`scripts/tests/fixtures/inputpath/synthetic-run/` (Law 3: unit test only, never under
`results/`; `python3 scripts/tests/inputpath_report_test.py --write-fixture` regenerates it).

```bash
make -s inputpath-report RUN=results/inputpath/<run-id> > /tmp/inputpath.md
```

**Inputs** (all inside the run dir):
- `manifest.json`, run.sh's, finalised: `.instance.type/.ami/.az`, `.truffle_price_usd_per_hour`,
  `.billed_seconds`, `.cost_usd`, `.cost_basis`, `.commit`, `.upstream`.
- `out/points.jsonl`: one JSON object per kraken2 run point, written by the harness.
- per point, its `pidstat_csv`, a path relative to the run dir.

**Outputs:** markdown on stdout and in `tables/inputpath-report.md` (or `OUT`), and
`tables/inputpath-summary.tsv` (one row per setting; `make report` renders it). Exit 0 with no
DEFECT, 1 with any DEFECT line (the report is still written), 2 on unreadable input (no run dir,
no or unfinalised manifest, invalid JSON, no points).

### Point record: `out/points.jsonl` (`"schema": "inputpath-point/1"`)

R = required when `status` is `ok`; O = optional, printed as `missing` when absent; n/a = not
applicable to the arm (printed `n/a`).

| field | type | | notes |
|---|---|---|---|
| `schema` | `"inputpath-point/1"` | O | |
| `point_id` | str | R | unique in the file |
| `rep` | int | O | repetition of the same setting, default 1 |
| `arm` | `I0`…`I4` | R | |
| `engine` | `upstream` \| `ours` | R | |
| `family` | str | R | `c8g`, `c9g`, `c8gn` |
| `instance_type` | str | R | must equal the manifest's `.instance.type` |
| `db` | str | O | database name; Law 1 groups by input and db |
| `p` | int | R for I2–I4 | rapidgzip `-P` per mate |
| `threads` | int | R | kraken2 `--threads` |
| `chunk_mib` | int | O | rapidgzip `--chunk-size`, MiB |
| `thp` | `always` \| `never` | R | |
| `pipe_bytes` | int | O | F_SETPIPE_SZ on the decoder's stdout |
| `fanout` | int | O | ours' fan-out width |
| `rapidgzip` | `{version, build: pypi\|source, isal: bool}` | O | I2–I4 |
| `input` | `{role: paired\|single, accession, mates: [{mate, s3_key, sha256}]}` | R (`accession`) | |
| `index_sha256` | str | O | I3 |
| `bgzf_sha256` | str | O | I4 |
| `fastq_bytes` | int | O | decompressed FASTQ bytes over all mates; MB/s = this / 10^6 / wall_s when `fastq_mb_per_s` is absent |
| `wall_s` | number | R | kraken2 wall time of the point |
| `classify_reads_per_s` | number | O | |
| `fastq_mb_per_s` | number | O | MB = 10^6 bytes |
| `classify_window` | `{t0, t1}` | O | in the pidstat CSV's `t_s` time base; absent = whole file |
| `pidstat_csv` | str | O | relative to the run dir |
| `peak_rss_kb` | `{kraken2, rapidgzip, …}` | O | |
| `output_sha256` | str | R | sha256 of `--output` |
| `report_sha256` | str | R | sha256 of `--report` |
| `identity` | `{gz_sha256, rg_sha256, rg_exit, ok}` | R for I2–I4 | rapidgzip vs `gzip -dc` |
| `status` | `ok` \| `skipped` \| `defect` | R | |
| `note` | str | O | |

`skipped` means recorded and never used, such as a rapidgzip crash or identity mismatch. Such a
point is listed and left out of every table and reading. `defect` is the harness's own defect and
is listed as a DEFECT.

**pidstat CSV** (one row per thread per 1 s sample, from `pidstat -t 1`): header
`t_s,tgid,tid,command,role,cpu_pct`, with `role` one of `rapidgzip`, `gzip`, `kraken2_reader`,
`kraken2_worker`, `kraken2_other`, `other`. If `role` is empty on kraken2 threads, the reader is
taken to be the kraken2 thread with the highest mean %CPU in the window, and the report says
"inferred".

### What the report contains

- The run table, from `manifest.json`, with the field cited on each row.
- **One table per family, engine and input:** one row per setting (arm × p × threads × chunk ×
  thp × pipe × fan-out). Repeated points are aggregated as the median and min–max of wall, plus
  FASTQ MB/s, classify reads/s, $/run, peak RSS, and `src` (the `out/points.jsonl` line numbers).
- **$/run:** the truffle price at launch × the setting's median `wall_s` / 3600. This is the
  point's wall-second share of the session at the launch price, compute only. The session's DB
  load, setup and idle time are not spread over the points; the report prints the used walls'
  share of the billed seconds. If `cost_usd` differs from price × billed by more than 1%, the
  report says so.
- **CPU attribution per arm at its best setting** (lowest median wall). It reads the pidstat CSV of
  the point whose wall is nearest the median, over its `classify_window`. Per role it gives the
  thread count, cores (the sum of the threads' mean %CPU / 100), share, and an ASCII bar. Each
  CSV is cited with its sha256.
- **Pins:** the rapidgzip version/build/ISA-L, the I3 index sha256 and the I4 BGZF sha256, each
  with its lines.
- **Law 1:** within each (input, db), every used point's `output_sha256` and `report_sha256` must
  equal those of the reference I0 point (upstream's I0 if present, else ours'). Each difference
  is a `DEFECT (Law 1)` line, and the point is left out of the tables. Other DEFECT kinds:
  - `(identity)`: an `ok` I2–I4 point whose identity check failed (rg_exit ≠ 0, the shas differ,
    or ok not true);
  - `(record)`: a required field is missing, an enum value is bad, a duplicate `point_id`, or
    `instance_type` ≠ the manifest's;
  - `(harness)`: `status: defect`;
  - `(Law 1 unverifiable)`: no usable I0 point for that input.

  Any DEFECT gives exit 1.
- **Readings**, per family, engine and input, then one summary line each.

### Reading rules

The thresholds are constants at the top of the script. Every comparison uses the median wall of
a setting.

- **Noise and resolution.** When both settings have n ≥ 2, the noise is the larger of their two
  min–max ranges, divided by the reference's median. If the noise is over 5%, the probe cannot
  resolve a 5% effect, so that comparison is *unresolved* and the reading is *undecided*
  (Law 4).
- **R1: I1 within 5% of I0** means single-stream gzip is struck from H-knee. Each I1 setting is
  compared with the best I0 at the same threads and thp. The reading *applies* if I1 ≤ I0 × 1.05
  at every matched setting. It *does not apply* if any matched setting exceeds that. It is
  *undecided* if there is no matched pair or a pair is unresolved.
- **R2: I2 or I3 reaches I0 at some p.** The reference is I0's best setting (lowest median wall
  over threads and thp). For each (p, arm), the best I2/I3 setting (over chunk and pipe) at the
  reference's threads and thp is compared with it. "Reaches" means
  (X − I0) / I0 ≤ the tolerance:
  - 5% if either side has a single point;
  - with n ≥ 2 on both sides, the noise, but at least 1%.

  The reading *applies* at the smallest p that reaches, which is the recommended setting. It is
  *undecided* if a smaller p is unresolved, or if nothing reaches and something is unresolved.
  The same line gives the plan's pipe cost: I2 at its best p vs I0, and whether that is under 10%.
- **R3: I0 limited by one saturated reader thread while the workers idle**, meaning upstream's
  serial parse and batch is the ceiling. The test uses I0's best setting, from its pidstat CSV
  over the classify window. The reading *applies* if the kraken2 reader thread's mean is ≥ 90%
  of one CPU and the kraken2 workers' mean is < 50%. It is *undecided* if there is no CSV or no
  reader or worker threads.
- **R4: I4 vs I2, the BGZF lever value.** The best I4 setting is compared with the best I2 at the
  same p, threads and thp. The value is reported as (I2 − I4) / I2, *within 5%* (no measurable
  value) or *beyond 5%*. It is *measured*, or *undecided* if no I4, no matching I2, or
  unresolved.
