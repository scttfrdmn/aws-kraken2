# make g0b / make harness

**What:** G0b equivalence runs of the Go ports against upstream at the pin, on real reads and
real databases, locally (no AWS). `make harness` builds the C++ oracle harnesses; `make g0b`
rebuilds them and runs the steps end to end.

```
make g0b                 # all steps
make g0b G0B=hash        # one step
G0B_DBS=viral make g0b   # restrict databases (default "viral standard8")
G0B_RUN_ID=x make g0b    # results dir suffix (default: UTC date)
```

| step | issue | compares |
|---|---|---|
| `hash` | #4 (G0b-1) | `internal/chash` vs upstream `CompactHashTable` (`compact_hash.h`) |

**Inputs:** the upstream checkout and the pinned databases and reads, from `make oracle`,
`scripts/fetch-db.sh` and `scripts/fetch-reads.sh`. Scripts find them in the main checkout
through git's common dir, so worktrees share them (`scripts/paths.sh`; override with
`K2_SHARED_ROOT`). A database whose download is incomplete (no `SOURCE` file) is skipped and
says so.

## Harnesses (`scripts/harness-build.sh`)

Every `upstream/*.cc` is compiled against the pinned sources with upstream's compiler choice
(Homebrew g++ on macOS, as `oracle-build.sh`) and the `CXXFLAGS` read out of upstream's own
`src/Makefile`, which at the pin include `-DLINEAR_PROBING`. Upstream's library sources are
compiled out of tree into `.oracle/harness/obj.*`; the shared checkout is never written. Each
harness is built twice: `<name>` with the shipped flags (the oracle) and `<name>.dh` without
`-DLINEAR_PROBING` (upstream's double-hashing build). `.oracle/harness/BUILD` records the
compiler, flags and pin.

## Step `hash`

For each database:

1. `chash_keys opts.k2d ...` runs upstream's `MinimizerScanner`, configured from `opts.k2d` as
   classify does, over SRR062634 (both mates). It writes every non-ambiguous minimizer above
   `minimum_acceptable_hash_value` (consecutive repeats kept) to `keys-real.u64`, and the same
   number of uniform random uint64 keys (splitmix64, fixed seed) to `keys-random.u64` as a
   miss-heavy control.
2. `chash_dump{,.dh} hash.k2d` looks every key up with upstream's `Get`, `GetBatch` and
   `FindIndex`, writing value and probe count (cells examined) per key.
3. `k2probe equiv-hash` looks the same keys up in Go and compares per key:
   - linear mode, RAM load and mmap load, vs the shipped build: **acceptance, 0 mismatches**;
   - double mode vs the `.dh` build: checks the Double port, must be 0 mismatches;
   - double mode vs the shipped build, counted (`-stop=false`): evidence for which probe mode
     the database was built with.

**Outputs:** `results/g0b/chash-<run-id>/`: `manifest.json`, `summary.md`, `commands.txt`,
the harness `BUILD`, and per database `db-SOURCE.txt`, `keys.txt` (scanner counts),
`upstream*-<pop>.txt` (upstream counts and timings), `go-*.{txt,json}` (comparison, probe
histograms for hits and misses, Go timings). Key and lookup dumps go to `.cache/g0b/<db>/`
and are not committed.

**Failure looks like:** `k2probe equiv-hash` stops at the first mismatch and prints the key,
its hash, home cell, compacted key, both answers and the cells along the probe path. The
script records a `FAIL:` line, keeps going with the other checks, and exits non-zero with
`"failed": 1` in the manifest. Timings are single-thread, warm page cache, on the machine named
in the manifest: they describe this probe, not the baseline (Law 2).
