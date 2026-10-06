# make g0c PART=local|probes|runs

**What:** G0c measures the occupied-run structure of RODA v205's `hash.k2d` (#7) and checks real
lookups' probe lengths against it (#8). Both are `cmd/k2probe` subcommands, run through
`make run` on AWS, after a local proof on the pinned databases. Backed by `scripts/g0c.sh`, the
specs `runs/g0c-runs.json` and `runs/g0c-probes.json`, and the post scripts
`scripts/post/g0c-{runs,probes}.sh`.

```bash
make g0c PART=local            # local proof (no AWS): Viral + Standard-8, brute force, sha256
make g0c PART=probes           # G0c-b (#8): the cheap rung, run it first
make g0c PART=runs             # G0c-a (#7): the 1.2 TB streaming pass
make g0c PART=runs DRY_RUN=1   # validate + spawn sizing plan, launch nothing
make orphans                   # run.sh already runs it; run it again after anything unusual
make -s report GATE=g0c RUN=<run-id>
```

`probes` and `runs` are exactly `make run GATE=g0c SPEC=runs/g0c-<part>.json` ([run.md](run.md)):
TTL, `cost_limit`, the region/Payer asserts, log streaming and `make orphans` all come from
there. The launch commit must be on GitHub, because the instance clones it.

## Definitions

- **Occupied:** a cell whose value (the low `value_bits` bits) is nonzero, the test upstream's
  probe loop stops on. Only 32-bit cells are supported; anything else fails.
- **Run:** a maximal stretch of occupied cells. The run that wraps from slot C-1 to slot 0 is
  joined into one run before anything is measured (`wrap_run_joined`).
- **Shards:** for N = 2, 4, …, 64, shard i owns slots `[floor(i*C/N), floor((i+1)*C/N))`, with
  C = capacity. Shard sizes differ by at most one slot when N does not divide C, and the
  boundaries for N are a subset of those for 2N. Shard N-1's boundary is C, the wrap: slot C-1 is
  followed by slot 0.
- **Tail at boundary b:** the cells past b that a shard ending at b-1 must hold so that no probe
  starting in it leaves it. A probe crosses b only if every cell from its home to b-1 is
  occupied. The probe that reads furthest is then a miss from inside the run containing b-1: it
  reads every occupied cell from b onward and then the empty cell that stops it. So
  `tail(b) = 0` if slot b-1 is empty, else `run_past(b) + 1`, slots mod C. The tail for N is the
  maximum over its N boundaries (`tables/tails.tsv`). `TestTailIsWhatProbesRead` checks this
  definition against `chash.Probe` itself, for every home slot of every shard of random tables.
  The global longest run is only an upper bound.
  **Scope of `tails.tsv`:** only power-of-two N from 2 to 64, cut at `floor(i*C/N)`. Any other
  shard count or cut point is not covered by it and must use the global longest-run bound: a
  tail is at most L cells (run_past <= L-1, plus the empty cell), so 302 for RODA v205, until
  it is measured.
- **Theory:** in the Poisson model of linear probing at load α = occupied/C, the expected number
  of runs of length L is `(C - occupied) · e^{-α(L+1)} (α(L+1))^L / (L+1)!`, a Borel
  distribution. Starting at an empty slot, the next block is the first passage of
  `Σ(X_i − 1)`, X_i ~ Poisson(α), to −1, by the hitting-time theorem. See Flajolet, Poblete and
  Viola, *On the analysis of linear probing hashing*, Algorithmica 22 (1998), and Knuth, TAOCP
  vol. 3, §6.4. `tables/hist.tsv` gives the residual, relative residual and z = residual/√expected
  per bucket. They are a cross-check and decide nothing. On RODA v205 the model **over-predicts
  the long-run tail** (`decoded/theory-tail.json`): −4.9% at 65–128, −16% at 129–256, 35 runs
  observed vs 82.3 expected at 257–512, and 1 run of length ≥ 302 observed vs 5.02 expected.
- **Probe counts (#8):** the cells `chash.Probe` examines, with the empty cell that ends a miss
  included. A **hit** is a lookup whose value is nonzero (a compacted-key match, which with
  `key_bits` = 10 includes some false positives). Knuth (TAOCP 3 §6.4, Algorithm L) gives hit
  `½(1 + 1/(1−α))` and miss `½(1 + 1/(1−α)²)`. The hit value is the **uniform-key null**: it
  averages over stored keys chosen uniformly, while real lookups are content-weighted, so it is
  a reference rather than an expectation for them (`knuth_hit_probes_uniform_key_null`). Misses
  are compared with Knuth and with `miss_probes_from_runs` from G0c-a, the exact mean miss length
  the measured runs imply: `(#empty + Σ_runs (L(L+1)/2 + L)) / C` (5.995 for RODA v205).

## PART=local

This runs `k2probe runs -file <db>/hash.k2d -brute` on the shared Viral and Standard-8 copies
(`scripts/paths.sh`). The streaming pass (parallel chunks, then an in-order merge) must equal
`runlen.Brute`, a separate sequential walk over the whole occupancy vector: every histogram
length, the totals, the longest run, and every boundary. Its SHA-256 must equal
`sha256sum`/`shasum -a 256`, and occupied and cells must equal the header's size and capacity.
It writes `results/g0c/local-<UTC>-<sha>/{manifest.json,<db>/…}` and exits non-zero on any
mismatch. Run it at a clean commit, because the manifest records the dirty flag.

## PART=probes (runs/g0c-probes.json)

This runs on a small Graviton instance (spawn sizing, families c8g/m8g/c7g/m7g).
1. **setup**: dnf (git, tar, gzip, jq), clone the launch commit, Go at `go.mod`'s version, and
   build `k2probe`.
2. **head**: an anonymous head-object of `hash.k2d`. The ETag and size are passed to `k2probe`,
   which sends `If-Match` on every GET. The post script checks the ETag against the manifest.
3. **fetch**: get `opts.k2d` anonymously. For each accession in `AK2_ACCESSIONS`, stage
   `<acc>_200000_{1,2}.fq` and `.SOURCE` with `ak2_stage` from `make stage-reads`'s prefix. Each
   file must match its sha256 metadata, and each FASTQ must match its SOURCE.
4. **probes**: `k2probe probes`. For each sample it scans every read pair as classify does
   (`internal/mmscan` with RODA's opts, then `classify.Tokens`: non-ambiguous minimizers that
   differ from the previous one in the same mate; `minimum_acceptable_hash_value` is 0). It draws
   10,000 lookups uniformly from that stream (Algorithm R, seed 1 mixed with the accession), then
   resolves each with `chash.Probe` over point GETs. The first GET is a 64 KiB window starting at
   the home slot. A probe that runs past the window fetches the next window, and one that passes
   slot C-1 fetches a window at slot 0. All workers share one source, so `get_requests` counts
   every GET (the header, each window and extension, every retry attempt), and `get_retries`
   counts the retries. `-runs-summary` takes G0c-a's `out/pass/summary.json` from the cloned
   commit (its ETag must match) for `miss_probes_from_runs`.

Outputs: `out/probes/lookups-<acc>.tsv` (one row per lookup), `probe-summary.tsv`,
`probe-hist.tsv` and `summary.json`. In `probe-summary.tsv`, `knuth` and `mean_minus_knuth`
are against Knuth (for hits, the uniform-key null), and `measured_runs` and
`mean_minus_measured_runs` are against `miss_probes_from_runs` (misses only). The post script
writes `decoded/{probes,opts,rules}.json` and `tables/{checks,probe-summary,probe-bands}.tsv`.
Its checks include that `get_requests` equals 1 + the per-sample GETs + retries.

## PART=runs (runs/g0c-runs.json)

This runs on one c8gn, sized by truffle for 8 vCPU and 16 GiB.
1. **setup** and **head**: as above.
2. **pilot** (the cheap rung): an in-memory SHA-256 benchmark (8 GiB) for the hash ceiling, then
   the first 32 GiB through the same reader, for the rates only.
3. **pass**: `k2probe runs -url … -etag … -size …`. It makes anonymous HTTPS ranged GETs of
   64 MiB, 48 in flight, each with If-Match the ETag; a 412 stops the pass. The reader is in
   order: each worker scans its chunk as it lands (`runlen.ScanChunk32`), and the single
   consumer feeds SHA-256 and merges the chunk summaries in slot order (`runlen.Accumulator`).
   SHA-256 is sequential, so the consumer bounds the pass. `sha_gb_per_s_while_busy`,
   `consumer_stall_seconds` (time spent waiting on the network) and the per-stream fetch rate
   show which bound applied. Progress goes to the run log every 32 GiB.
4. **head-after**: head-object again. The ETag must not have changed.

Nothing is read from a local disk, so there is no page cache, no cold or warm distinction, and
no `drop_caches`.

Outputs: `out/pass/{summary.json,hist.tsv,hist-raw.tsv,boundaries.tsv,tails.tsv}` and
`out/pilot/summary.json`. `hist-raw.tsv` holds every observed length exactly. `hist.tsv` holds
1..64 exactly, then log2 buckets `(2^(k-1), 2^k]`, against theory. `boundaries.tsv` has one row
per boundary of N = 64 (`first_N` is the smallest N that has it), with `run_past`, `tail` and
the run containing slot b-1. The post script checks that the ETag is the same at launch, before,
via If-Match and after; that bytes streamed equals the size; that cells equals capacity; and
that occupied equals the header size. The ETag row is enforced in code: `internal/rangeread`
sends If-Match on every GET and checks each response's ETag and Content-Range. It then records
the SHA-256 in `manifest.json` next to the dataset's ETag/VersionId (`datasets[].sha256`,
`sha256_source`, `sha256_check`), the one manifest write [run.md](run.md) allows a post script.
It writes `decoded/{object,pass,rules,theory-tail}.json` and
`tables/{checks,rates,tails,hist,boundaries}.tsv`.

## Failure looks like

- `brute-force cross-check FAILED` or `coverage check FAILED` from `k2probe`: a counting defect.
  Nothing from that commit is trusted.
- `ETag is no longer … (412)`: the object changed mid-pass. The pass stops; rerun it.
- `g0c-*.post: a check failed`, exit 98: `tables/checks.tsv` names the row.
- No `out/pass/summary.json` after a TTL kill: `log/run.log` has the progress lines (bytes, rates,
  occupied so far). Raise the TTL only after reading them.
