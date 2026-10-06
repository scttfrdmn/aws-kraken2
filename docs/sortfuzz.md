# make sortfuzz (scripts/sortfuzz.sh)

**What:** a black-box differential fuzz of `internal/report`'s
`stdSort(a []uint64, less func(x, y uint64) bool)` against libstdc++'s `std::sort` (#35). Upstream
orders report siblings with `std::sort`, which is not stable. Report output is byte-identical
only if `stdSort` leaves elements in exactly the order libstdc++ does, ties and the heapsort
fallback included.

```
make sortfuzz [SORTFUZZ=quick|full]      # default quick
SORTFUZZ_SEED=N make sortfuzz ...        # another corpus (default seed 35)
```

**How it works:**
- `upstream/sortfuzz.cc` is built by `scripts/harness-build.sh sortfuzz`, so it uses the same
  compiler (`scripts/cxx.sh`) and upstream's CXXFLAGS (`-std=c++11 -O3 ...`). It reads cases from
  stdin, sorts each with `std::sort` and the comparator of upstream's `KrakenReportDFS`
  (`src/reports.cc`): if a is absent from the counter map, false; else if b is absent, true; else
  `count(a) > count(b)`. It writes back the output order of the ids, the comparator call count,
  and how many times the heapsort fallback was entered. The wire format is in the file's header.
- `internal/report/sortfuzz_test.go` (`TestSortFuzzHeapProbe`, `TestSortFuzz`) generates the corpus
  from the seed. It streams the cases to one sortfuzz process, sorts the same ids in the same
  initial order with `fuzzSort` (= `stdSort`) and the same comparator (report.go's), and compares
  the permutations. It stops at the first mismatch. The tests skip unless `SORTFUZZ_BIN` is set,
  so `make test` does not run them.

**Heapsort detection:** in libstdc++, `std::sort` is `__introsort_loop` followed by an insertion
sort. The loop calls `std::__partial_sort(first, last, last, comp)` exactly when its depth limit
(2·floor(lg n)) runs out on a range longer than 16. Nothing else on `std::sort`'s path calls it.
sortfuzz sorts through its own thin random-access iterator, `TagIt`, and declares an explicit
specialization of `std::__partial_sort<TagIt, C>`. The specialization counts the call, then runs
the unspecialized libstdc++ template on the same range through raw pointers. libstdc++ itself is
not modified.

`C` is the comparator type at that call. GCC < 16 passes `__gnu_cxx::__ops::_Iter_comp_iter<Comp>`
there and GCC 16 passes `Comp` itself; `_GLIBCXX_RELEASE` selects the matching specialization.

Two guards keep the detection honest:
- Every case is sorted a second time with plain `std::sort` on `std::vector<uint64_t>::iterator`,
  upstream's exact call. Any difference aborts sortfuzz (exit 3).
- A specialization that never matched would read as zero hits everywhere, and the run fails on
  zero hits.

`TestSortFuzzHeapProbe` shows the detection working in both directions:
- a McIlroy killer of length 4096 reports 1 fallback in about 154k comparisons;
- sorted and reverse input of length 4096 report 0 (median-of-3 splits them evenly);
- length 16 reports 0 (the loop never runs at n ≤ 16).

**Corpus** (`fuzzSizesFor` in the test; quick / full):

| part | quick | full |
|---|---|---|
| structured: all-equal, all-absent, sorted, reverse, sorted/reverse with ties, sorted with an absent tail, reverse with an absent head | every n 0..2048 | every n 0..2048 |
| every n 0..2048, random tie density | 1 per n | 4 per n |
| dense n 8..40 (around 15, 16, 17 and 32) | 40 per n | 400 per n |
| median-of-3 killers × 7 variants | n = 17..200 step 3, 256, 511, 512, 1024, 2048, 4096 | n = 17..512, 519..2048 step 7, 2048, 4095, 4096, 8192, 16384, 32768 |
| random, heavy ties | 20 000 | 1 000 000 |

Details of each part:
- **Random cases:** 55% have n ≤ 64, 35% have n in 65..512 and 10% have n in 513..2048. The key
  alphabet runs from 1 to 2^30 values, weighted towards small sizes. The absent rate is
  0/2/10/30/60/90/100%. The shapes are uniform, skewed, one dominant key, descending or ascending
  with noise, organ pipe and sawtooth. Keys are sometimes scaled or offset.
- **Killers:** `sortfuzz --killer N` runs McIlroy's adversary ("A Killer Adversary for Quicksort",
  1999) against this `std::sort`. Gas items left unfrozen become tied keys. Each killer is fed in
  7 variants: raw; gas absent; keys halved; keys quartered; 1 to 3 random swaps; rotated by one;
  and padded with random keys.

**Outputs:** `results/g1/sortfuzz-<UTC ts>-<short sha>/`:
- `manifest.json`: commit and whether the tree was dirty; the upstream pin and `git describe`;
  the compiler (`$CXX --version`) and the oracle's own version line (`__VERSION__`,
  `_GLIBCXX_RELEASE`, `__GLIBCXX__`); the runtime libstdc++ path and the harness `.BUILD` record;
  the sortfuzz sha256 and Go version; the host (OS release, arch, kernel, whether it is a
  container, and whether it is the canonical toolchain); the corpus mode, seed and sizes; the
  results; and `failed`.
- `summary.json`, `summary.md`: written by the test. They give cases, elements, mismatches,
  heapsort-hit cases and calls, the n range, distinct n, whether every n 0..2048 was covered,
  case counts at n = 15/16/17/32, and a per-category table.
- `run.log`: the `go test -v` output.
- `mismatch.json` (on a mismatch only): the full failing case (ids and keys in input order), both
  orders, the first differing position and the C++ heapsort count.

**Pass:** exit 0 means all of the following held:
- 0 mismatches;
- at least one case hit the heapsort fallback, and at least one raw killer did;
- every n from 0 to 2048 was covered;
- the probe test passed.

Anything else exits 1.

**Canonical toolchain:** the order is defined by libstdc++'s headers. CI job `sortfuzz` runs
`make sortfuzz SORTFUZZ=full` in `amazonlinux:2023` (GCC 11.5.0 and its libstdc++) on
ubuntu-24.04-arm. Results on other toolchains (for example Homebrew GCC 16 on macOS) are
development evidence. The manifest's `canonical_platform` is true only on Linux aarch64 with
Amazon Linux 2023.

To run the canonical job locally with podman or docker, start `amazonlinux:2023` with:
- the repository mounted;
- `dnf install gcc-c++ make git tar gzip zlib-devel perl perl-Digest-SHA jq findutils`;
- the Go toolchain named in `go.mod`;
- `K2_SHARED_ROOT` pointing at a checkout holding `.oracle/src-<pin>`.

Then run `make sortfuzz SORTFUZZ=full`.

**Testing a new implementation:** replace `stdSort` (same signature) and run
`make sortfuzz SORTFUZZ=full`. To try a candidate without replacing it, temporarily point
`fuzzSort` in `sortfuzz_test.go` at the candidate.

**Failure looks like:**
- `sortfuzz: FAILED (see results/g1/sortfuzz-.../summary.md ...)`;
- `--- FAIL: TestSortFuzz` with a `MISMATCH:` block giving the case index, category and n, the
  C++ heapsort count, the first differing position, the input (first 64 elements) and the two
  orders around the difference;
- or a failure naming the unmet condition, such as `the heapsort fallback was never hit`;
- or `sortfuzz: harness build failed` (see docs/harness.md).
