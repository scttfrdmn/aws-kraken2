# HitCounts: upstream's hit_counts iteration order (#44)

**What:** `internal/classify/hitorder.go` defines `HitCounts`, the stand-in for upstream's
per-thread `hit_counts` (`taxon_counts_t`, `std::unordered_map<taxid_t, uint64_t>`), and the
operations classify.cc performs on it. ResolveTree's call depends on its iteration order when a
score tie's LowestCommonAncestor is 0. RODA v205's taxonomy has 246 orphan nodes
(`k2probe taxo-orphans`), and on 16 reads of three HMP2 samples our first-hit order differed from
upstream (#44). Scott chose a clean-room implementation, as for #35. This page is the black-box
test harness's interface only. It does not describe how any standard library orders entries.

## The harness: upstream/umap_order.cc

The harness uses the C++ standard library as a library. It is built against upstream's src at
the pin, for the `taxon_counts_t` typedef. It reads an op history on stdin and writes one line
per `P`. One process is one map's lifetime, like one classify.cc thread's.

| op | meaning | classify.cc at the pin |
|---|---|---|
| `C` | `hit_counts.clear()` | :971, once per read |
| `I <taxon>` | `hit_counts[taxon]++` | :1085, per hit, in hit order |
| `L <taxon>` | `hit_counts[taxon]` as an rvalue, which inserts the taxon when it is absent | :927, `max_score = hit_counts[max_taxon]` |
| `P` | prints `P <bucket_count()> <taxon> <taxon> ...` in iteration order | the walks of :905, :909, :931 |

Taxa are unsigned decimal integers.

`make hitorderfuzz` (docs/hitorderfuzz.md) adds four ops: `N` (a fresh map), `V` (taxa with their
counts, and `size()`), `B` (bucket count and size) and `G <taxon>` (`L`, printing the value read).
Histories without them behave as before, so the golden data below is unchanged.

## Golden data: internal/classify/testdata/umap/

- `ops-<k>.txt.gz` holds seven op histories from `scripts/tests/umap_cmds.py` (seeded).
  - Per read: `C`, then `I` for each hit (repeats included), `P`, an `L` of a present, absent or
    0 taxon, and `P` again.
  - Sessions vary read sizes (1 to 600 distinct taxa) and taxon ranges, up to 2^31 and RODA
    v205's internal ID range.
- `ops-<k>.out.gz` holds the harness's output for each history.
- **Provenance:** `make hitorder-golden` (`scripts/hitorder-golden.sh`) builds the harness with
  Amazon Linux 2023's system g++, in podman. That is the toolchain upstream is built with on the
  instances. `gxx.txt` records the compiler: g++ (GCC) 11.5.0 20240719 (Red Hat 11.5.0-5). The
  build uses upstream's src at 2731b35f7abb26ec926517274f3d87e78d42fd76, and the harness then
  runs each history.

## Testing a Go implementation

`go test ./internal/classify/ -run 'HitCountsGolden|Issue44'`

- **`TestHitCountsGolden`** replays every history through `newHitCounts()`:
  - `C` maps to `Clear`, `I` to `Increment`, `L` to `Lookup`;
  - at each `P`, the taxa `Range` yields must equal the golden line's taxa, in order;
  - the golden line's bucket count is not part of the interface and is not compared.
  - **Pass** means every print of every history matches.
- **`TestIssue44OrphanTies`** replays all 16 real reads through the public API.
  - It uses upstream's own events and values on RODA v205 (`testdata/issue44_events.jsonl`,
    recorded by the RODA recheck) and RODA lineages.
  - It requires upstream's `--output` line byte for byte.
  - It fails on all 16 with the pre-fix first-hit order (0a5105c), and passes with the
    clean-room `newHitCounts` (`hitcounts.go`, 904c2a5).
  - It is a **regression check, not an order discriminator**. The reverse of first-insertion
    order also passes all 16, although it differs from upstream's order in general (checked
    locally at this commit). The clean-room order with `Range` reversed fails all 16.
    Discrimination rests on `TestHitCountsGolden` and on the differential fuzz, whose
    sensitivity runs (reversed, first-hit) must fail.
- **Residual exposure:** the container's iteration order depends on its bucket count, which a
  map keeps across `clear()` for its whole thread lifetime. Each worker thread's map therefore
  carries the history of the reads that thread classified before.
  - Upstream's thread-to-read assignment is not deterministic, and nor is ours, so on a read
    whose call depends on the order, the result could depend on which reads its worker saw
    earlier.
  - This applies to upstream and to us alike.
  - It was not observed: U1's six configurations, U2's, and our cohorts agree on every read.
- To extend the golden data, add sessions to `umap_cmds.py` and rerun `make hitorder-golden`.
- The differential fuzz, `make hitorderfuzz [HITORDERFUZZ=quick|full]`, runs the same comparison
  (orders and counts) on generated histories against the live container: every rehash boundary
  up to 100 000 elements, clear cycles, lookups of absent taxa, and the #44 reads
  (docs/hitorderfuzz.md).
