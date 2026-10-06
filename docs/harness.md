# make harness (scripts/harness-build.sh)

**What:** builds the C++ oracle harnesses in `upstream/*.cc`. Each one links against upstream's
own code at the pin, so a Go port can be compared with the code it ports. The harnesses are not
part of the core path.

```
scripts/harness-build.sh [-v lp|dh|lp,dh] [name...]
make harness [NAME="chash_dump mm_dump"] [VARIANTS=lp,dh]
```

- `name...`: the harnesses to build. With no names, every `upstream/*.cc` is built.
- `-v lp` (the default) builds `<name>` with upstream's default flags. These include
  `-DLINEAR_PROBING`, so this is the oracle. `-v dh` builds `<name>.dh` with the same flags minus
  `-DLINEAR_PROBING`, which is upstream's double-hashing build. `-v lp,dh` builds both.
- stdout gets one absolute path per built binary, in argument order, with `<name>` before
  `<name>.dh`. Callers capture these paths; they never guess them.

**How it builds:**
- **Compiler:** `scripts/cxx.sh`, the same choice `scripts/oracle-build.sh` makes. That is the
  system `g++` on Linux and the newest Homebrew `g++-N` on macOS (Apple clang has no `-fopenmp`).
  `$CXX` overrides it.
- **Flags:** `CXXFLAGS` and `LDFLAGS` are read out of upstream's `src/Makefile` by running make
  against it, not restated here. If `-DLINEAR_PROBING` is absent, the script stops, because the
  `dh` variant would then silently equal the oracle. `-lz` is added at link time.
- **Upstream library code:** every `src/*.cc` without a `main`, except the libtax shim. It is
  compiled once into `.oracle/harness/<pin>/lib-<variant>-<key>/libkraken2.a`. The `<key>` hashes
  the pin, the compiler version, the flags and every upstream `src/*.{h,cc}`, so a change to any of
  them builds a fresh archive.
- **Upstream checkout:** the shared checkout comes from `scripts/paths.sh` (see below) and is only
  ever read. It must be at the pin with no tracked modifications, otherwise the script exits
  non-zero. Every object file is written under this checkout's `.oracle/harness/`.

**Outputs:**
- `.oracle/harness/<pin>/<name>[.dh]`: the binaries. They live in *this* checkout, because
  harness sources differ per branch.
- `<name>[.dh].BUILD` beside each binary. It records the pin, the upstream tree state and the
  sha256 of its sources, the harness source sha256, the variant, the compiler and its version, the
  flags, the archive and the build time and host.

Go tests find harnesses with `oracletest.Harness(t, name)`. Scripts take the paths from
stdout.

## Shared resources (scripts/paths.sh, internal/oracletest)

The upstream checkout and build (`.oracle/src-<pin>`, `.oracle/<pin>`), the databases
(`.cache/db`) and the reads (`.cache/reads`) are large. They exist once, in the main checkout,
and git worktrees reach them through git's common dir:
- scripts source `scripts/paths.sh`, which sets `K2_SHARED_ROOT`, `ORACLE_SRC`, `ORACLE_DST`,
  `K2_DB_ROOT` and `K2_READS`;
- Go tests use `internal/oracletest` (`Root`, `Upstream`, `DB`, `Reads`, `Need`), which follows
  the same rule.

In both, `K2_SHARED_ROOT` overrides the root, and so does `AWS_KRAKEN2_ROOT` in Go. A test skips
when an artifact is absent. With `AWS_KRAKEN2_REQUIRE_ORACLE=1`, it fails instead. `AWS_KRAKEN2_DBS` (space-separated database directory names) names the databases a run provides; a test of any other database skips even then, which is how CI requires Viral without Standard-8.

**Failure looks like:**
- a non-zero exit with `harness-build: ...` naming the cause: no upstream source, not at the pin,
  tracked modifications, or no `-DLINEAR_PROBING`;
- or the last 30 lines of the compiler log.
