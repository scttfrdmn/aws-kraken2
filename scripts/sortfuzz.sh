#!/usr/bin/env bash
# make sortfuzz [SORTFUZZ=quick|full] (docs/sortfuzz.md, issue #35): differential fuzz of
# internal/report's stdSort against libstdc++'s std::sort.
# Builds upstream/sortfuzz.cc with scripts/harness-build.sh (scripts/cxx.sh's compiler, upstream's
# CXXFLAGS), runs TestSortFuzzHeapProbe and TestSortFuzz in internal/report, and writes
# results/g1/sortfuzz-<UTC ts>-<short sha>/{manifest.json,summary.json,summary.md,run.log}
# (plus mismatch.json on a mismatch). SORTFUZZ_SEED overrides the corpus seed (default 35).
# Exit 0 only if the tests pass: no mismatch, the heapsort fallback hit, n 0..2048 all covered.
set -uo pipefail
set +e
echo "sortfuzz: shell flags $-"
cd "$(dirname "$0")/.." || exit 1
MODE=${1:-quick}
case "$MODE" in quick|full) ;; *) echo "usage: $0 [quick|full]" >&2; exit 2 ;; esac
SEED=${SORTFUZZ_SEED:-35}
. scripts/pin.env
. scripts/paths.sh
for c in jq git go; do command -v "$c" >/dev/null || { echo "sortfuzz: need $c" >&2; exit 1; }; done

BIN=$(scripts/harness-build.sh sortfuzz) || { echo "sortfuzz: harness build failed" >&2; exit 1; }
. scripts/cxx.sh
TS=$(date -u +%Y%m%dT%H%M%SZ)
SHA=$(git rev-parse HEAD)
RES="results/g1/sortfuzz-$TS-${SHA:0:7}"
mkdir -p "$RES" || exit 1
start=$(date -u +%FT%TZ)
SORTFUZZ_BIN="$BIN" SORTFUZZ="$MODE" SORTFUZZ_SEED="$SEED" SORTFUZZ_OUT="$PWD/$RES" \
  go test -count=1 -v -timeout 0 -run '^TestSortFuzz' ./internal/report/ > "$RES/run.log" 2>&1
st=$?
stop=$(date -u +%FT%TZ)
tail -25 "$RES/run.log"

ORACLE_VERSION=$("$BIN" --version)
LIBSTDCXX=$("$CXX" -print-file-name=libstdc++.so 2>/dev/null)
[ "$(uname -s)" = Darwin ] && LIBSTDCXX=$("$CXX" -print-file-name=libstdc++.dylib 2>/dev/null)
OSREL=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || sw_vers -productVersion 2>/dev/null || echo unknown)
CXXV=$("$CXX" --version | head -1)
CANON=false
case "$(uname -sm)" in "Linux aarch64") case "$OSREL" in "Amazon Linux 2023"*) CANON=true ;; esac ;; esac
SUMMARY="$RES/summary.json"; [ -s "$SUMMARY" ] || SUMMARY=/dev/null
DIRTY=false; [ -n "$(git status --porcelain --untracked-files=no)" ] && DIRTY=true
jq -n \
  --arg what "make sortfuzz: internal/report stdSort vs libstdc++ std::sort, permutation identity (#35)" \
  --arg inv "scripts/sortfuzz.sh $MODE" --arg mode "$MODE" --argjson seed "$SEED" \
  --arg commit "$SHA" --argjson dirty "$DIRTY" --arg pin "$UPSTREAM_PIN" \
  --arg describe "$(git -C "$ORACLE_SRC" describe --tags 2>/dev/null)" \
  --arg cxx "$CXX" --arg cxxv "$CXXV" --arg oracle "$ORACLE_VERSION" --arg lib "$LIBSTDCXX" \
  --arg build "$(cat "$BIN.BUILD")" --arg bin_sha "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" \
  --arg go "$(go version)" --arg host "$(uname -n)" --arg os "$(uname -s)" --arg arch "$(uname -m)" \
  --arg kernel "$(uname -r)" --arg osrel "$OSREL" --argjson canon "$CANON" \
  --arg start "$start" --arg stop "$stop" --argjson status "$st" \
  --slurpfile s "$SUMMARY" \
  '($s[0] // null) as $sum |
   {gate:"g1", what:$what, invocation:$inv, commit:$commit, dirty:$dirty, upstream_pin:$pin,
    upstream_describe:$describe,
    compiler:{cxx:$cxx, version:$cxxv, oracle_version_line:$oracle, libstdcxx_runtime:$lib,
              harness_build:$build, sortfuzz_sha256:$bin_sha},
    go:$go,
    host:{name:$host, os:$os, arch:$arch, kernel:$kernel, os_release:$osrel,
          canonical_platform:$canon,
          note:(if $canon then "canonical platform (Amazon Linux 2023, Linux aarch64)" else "NOT the canonical platform (amazonlinux:2023 on Linux aarch64): development evidence only" end)},
    corpus:{mode:$mode, seed:$seed, sizes:($sum.sizes // null)},
    results:(if $sum == null then null else
      {cases:$sum.cases, elements:$sum.elements, mismatches:$sum.mismatches,
       heap_cases:$sum.heap_cases, heap_calls:$sum.heap_calls, min_n:$sum.min_n, max_n:$sum.max_n,
       distinct_n:$sum.distinct_n, every_n_0_to_2048:$sum.every_n_0_to_2048,
       cases_at_n:$sum.cases_at_n, seconds:$sum.seconds, failure:($sum.failure // "")} end),
    start:$start, stop:$stop, go_test_status:$status,
    failed:($status != 0 or $sum == null or ($sum.pass | not))}' > "$RES/manifest.json" || st=1
if [ "$st" = 0 ] && jq -e '.failed == false' "$RES/manifest.json" >/dev/null; then
  echo "sortfuzz: ok ($RES)"
  exit 0
fi
echo "sortfuzz: FAILED (see $RES/summary.md and $RES/run.log)" >&2
exit 1
