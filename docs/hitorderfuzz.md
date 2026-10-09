# make hitorderfuzz (scripts/hitorderfuzz.sh)

**What:** a black-box differential fuzz of `internal/classify`'s `HitCounts` (whatever
`newHitCounts()` returns; the interface is `internal/classify/hitorder.go`) against upstream's
`taxon_counts_t`, `std::unordered_map<unsigned long, unsigned long>`, as Amazon Linux 2023's
g++ 11.5.0 compiles it (#44). ResolveTree's call depends on the map's iteration order
(docs/hitorder.md), so `--output` is byte-identical only if `Range` visits the entries in exactly
the container's order after the same operations since the map was created. Like
docs/hitorder.md, this page describes the test, not how any standard library orders entries.

```
make hitorderfuzz [HITORDERFUZZ=quick|full|selftest]    # default quick
HITORDERFUZZ_SEED=N make hitorderfuzz ...                # another corpus (default seed 44)
HITORDERFUZZ_ONLY=random,growth make hitorderfuzz ...    # only these categories (never a pass)
```

**Pass:** exit 0 means all of the following held:
- no mismatch: at every `P`/`V` of every history, the taxa `Range` yields, in order, and (at `V`)
  their counts equal the container's; at every `G`, `Lookup`'s return equals the value the
  container read; every `Lookup` returns the count;
- every coverage target was met (below);
- the harness produced exactly one line per print and exited 0.

Anything else exits 1: `hitorderfuzz: FAILED (see results/g1/hitorderfuzz-.../summary.md ...)`.
A partial run (`HITORDERFUZZ_ONLY`) always exits 1; it is for locating or demonstrating a
mismatch in one category.

## How it works

- **The C++ side** is `upstream/umap_order.cc` (docs/hitorder.md), built with
  `g++ -std=c++11 -O3` against upstream's `src/` at the pin.
  - On Amazon Linux 2023 with g++ 11.5.0 (the CI job) it is built and run natively.
  - Anywhere else it is built and run in podman (`public.ecr.aws/amazonlinux/amazonlinux:2023`,
    `dnf install gcc-c++`), and the binary runs in the same image against its system libstdc++,
    as upstream's binary does on the instances.
  - The script fails unless `g++ -dumpfullversion` is 11.5.0.
- **The ops** for this target are extensions of the harness; histories without them behave as
  before (the golden data of `make hitorder-golden` is unaffected):

  | op | meaning |
  |---|---|
  | `N` | end this map's lifetime and start a new one (one process runs every history) |
  | `V` | print `V <bucket_count()> <size()> <taxon>:<count> ...` in iteration order |
  | `B` | print `B <bucket_count()> <size()>` |
  | `G <taxon>` | as `L`, and print `G <count>`, the value read |

- **The Go side** is `TestHitOrderFuzz` (`internal/classify/hitorderfuzz_test.go`, skipped
  unless `HITORDERFUZZ_CMD` is set, so `make test` does not run it). Every history starts with
  `N`, and is replayed through a fresh `newHitCounts()`: `C` is `Clear`, `I` is `Increment`,
  `L` and `G` are `Lookup`, and `P` and `V` are `Range`. A model map of counts checks the
  container's `size()` and `Lookup`'s value. `B` is coverage bookkeeping only. Bucket counts are
  not part of the interface and are never compared.
- **Streaming:** one harness process takes the whole corpus on stdin. The generator runs twice
  from the same seed, once to write the ops and once to replay them against the output, so
  nothing is held in memory. The first mismatch stops the run.
- **The probe:** before the corpus, a separate harness run inserts keys 1..150000 into a fresh
  map with `B` after each. It yields the container's bucket-count sequence and the sizes at
  which it changes (`probe.tsv`). The generator uses them to make keys collide modulo each bucket
  count, and to place dumps on both sides of every boundary. The coverage targets are defined by
  them.

## Corpus (seed 44 by default; quick / full / selftest)

| category | what | quick | full | selftest |
|---|---|---:|---:|---:|
| `real` | the 16 #44 reads (`testdata/issue44_events.jsonl`: upstream's own events and values on RODA v205, recorded by the #44 RODA recheck; the orphan they hit is internal 2158558): one lifetime, each read alone (3 lookup shapes), and shuffled repeats; plus `real/recorded-classify`, the op history our own classifier performs on `HitCounts` while classifying them | 100 rounds | 1000 rounds | 3 rounds |
| `lookup` | read-shaped histories with a lookup (mostly of an absent taxon) after about every second increment | 20 000 | 200 000 | 300 |
| `random` | read-shaped histories: 1 to 4 reads, `C` per read (or, 1 in 20, none), 1 to about 2000 distinct taxa per read with repeats as runs or shuffled, an occasional lookup, ResolveTree's end shape (`V`, a lookup of a present, absent or 0 taxon, `V`) | 100 000 | 1 000 000 | 1500 |
| `clear-random` | 250 (full: 500) clear cycles in one lifetime; refills from 0 to 6000, a third around a boundary; `B` before and after each `C` | 120 | 600 | 10 |
| `clear-beyond` | for each bucket count b in the sequence: fill to the largest size at b, `C`, refill past the boundary out of b (`B` after each insert, `V` on both sides), then two small refills; taxid and colliding keys | 2 per b | 2 per b | 2 per b |
| `growth` | one map grown to 100 000 elements, `B` after every op, `V` at 0, s−1, s, s+1 for every boundary s and at powers of two; variants: sequential, taxid, huge, colliding modulo the current bucket count, crossing by `G`, crossing by `L` (full adds reverse, taxid with repeats, dense then huge, mixed) | 6 | 10 | 6 |

Key distributions (per history): dense (0 or 1 up to 1..1000), colliding (congruent modulo one to
three bucket counts from the probe, low or near 2^64), huge (near 2^64, around 2^63, colliding
near 2^64, or any 64-bit), taxid (uniform to 2.2M, clustered, RODA v205's 246 orphan IDs with
real-like hits, or with an occasional 0), and mixed. Dumps come every 1 to 4 ops while a map is
small, and every 1 to min(size, 512) ops once it is larger.

`real/recorded-classify` depends on the implementation under test: the classifier's
`Lookup(max_taxon)` follows from the order its `Range` gave. With a correct implementation it is
upstream's own history on these reads.

## Coverage targets (the run fails if one is missed)

- `random` histories: at least the mode's count.
- Every boundary of the probe's sequence up to 100 000 elements (1→13 ... 85229→172933 with
  AL2023's toolchain) crossed between two `V`s by exactly one `I`, and by exactly one `G` or `L`.
- Every bucket count b > 1 below that size retained across a `C` and then refilled beyond.
- Clear cycles: at least 100 000 (full 1 000 000; selftest 2000).
- Absent-taxon lookups right after an increment: at least 10 000 (full 100 000; selftest 300).
- Every `real` history replayed.

## Outputs: results/g1/hitorderfuzz-\<UTC ts\>-\<short sha\>/

- `manifest.json` holds:
  - the commit, whether the tree was dirty, and the upstream pin with its `git describe`;
  - the compiler: the `g++ --version` line, `-dumpfullversion`, the flags, the `rpm -q` lines for
    gcc-c++, libstdc++-devel, libstdc++ and glibc, the OS and arch, and the runtime libstdc++;
  - for podman, the image and its digest; the sha256 of the umap_order binary and of the source;
  - the Go version and the host;
  - the corpus mode, seed, `HITORDERFUZZ_ONLY`, sizes, and the probe's bucket counts and
    boundaries;
  - the results, the start and stop times, and `failed`.
- `summary.json` and `summary.md`: written by the test from its own counters. They give the
  failures, the op, print, entry, lookup and clear counts, the histories passed per category, the
  per-boundary coverage table, and the first mismatch.
- `probe.tsv`: the probe's sizes and bucket counts.
- `run.log`: the `go test -v` output.
- `mismatch.txt` and `mismatch-ops.txt` (on a mismatch only). `mismatch.txt` holds the seed, the
  history's category and number, the op index and op, both full dumps, and the first differing
  entry. `mismatch-ops.txt` is the history up to and including that op;
  `umap_order < mismatch-ops.txt` replays it.

**Failure looks like:**

```
MISMATCH: V: first difference at entry 0 (Go 1730567:5, container 2158313:5)
history real/lifetime #0, op 19 (V); see .../mismatch.txt
around entry 0:
 Go        entries [0:4] of 4: 1730567:5 1924416:2 1844350:5 2158313:5
 container entries [0:4] of 4: 2158313:5 1844350:5 1924416:2 1730567:5
```

The other failures name the unmet target (for example
`boundaries not crossed by a lookup between two dumps: ...`), or `harness protocol`, or the
model's size check (a harness or model defect, not the implementation's).

## Selftest

`HITORDERFUZZ=selftest` puts the container itself on the Go side: a second, line-buffered
umap_order process (`stdbuf -oL`) answers `Lookup` and `Range`. It must pass. It checks the
comparison, the streaming and the coverage targets end to end on the real toolchain, without any
Go implementation of the order. It is small, because every print is a round trip.

## Sensitivity

Before trusting a pass, the fuzz must be able to fail. Two orders known to be wrong must FAIL:
- the first-insertion-order placeholder (`TODO(#44 clean-room)`);
- the same implementation with `Range` reversed.

`HITORDERFUZZ_SENSITIVITY=reversed|first-hit make hitorderfuzz` runs either in place of
`newHitCounts` (`hitorderfuzz_sens_test.go`). The run is recorded in
`results/g1/hitorderfuzz-<ts>-<sha>-sens-<kind>/` and exits 0 only if the fuzz failed on a
mismatch.

## Canonical toolchain and CI

CI job `hitorderfuzz` runs `make hitorderfuzz HITORDERFUZZ=full` in `amazonlinux:2023` on
ubuntu-24.04-arm, after asserting `g++ -dumpfullversion` = 11.5.0. It must pass: `newHitCounts` is the clean-room implementation (`hitcounts.go`, 904c2a5).
the clean-room implementation lands. Locally, the podman path uses the same image and toolchain.

**Testing a new implementation:** replace `newHitCounts` (hitorder.go) and run
`make hitorderfuzz HITORDERFUZZ=full`. To try a candidate without replacing it, temporarily point
`fuzzNewHitCounts` in `hitorderfuzz_test.go` at it.
