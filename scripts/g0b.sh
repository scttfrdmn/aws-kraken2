#!/usr/bin/env bash
# G0b equivalence runs: Go ports vs upstream at the pin, on real reads and real databases.
# Usage: scripts/g0b.sh hash|all        (other G0b steps add their own case below)
# Env:   G0B_DBS     databases to run (default "viral standard8"; an incomplete download is skipped)
#        G0B_RUN_ID  results directory name suffix (default: UTC date)
# Writes results/g0b/<step>-<run-id>/ (small summaries) and .cache/g0b/ (key and output dumps).
set +e
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
echo "g0b: shell flags $-"

STEP=${1:-all}
RUN_ID=${G0B_RUN_ID:-$(date -u +%F)}
DBS=${G0B_DBS:-viral standard8}
READS=SRR062634_200000
SEED=20261005
FAILED=0

db_dir() {
  case "$1" in
    viral) echo "$K2_DB_ROOT/k2_viral_20260626" ;;
    standard8) echo "$K2_DB_ROOT/k2_standard_08_GB_20260626" ;;
    *) echo "g0b: unknown db $1" >&2; return 1 ;;
  esac
}

# fail MSG: record a failed acceptance check and keep going (the summary says which).
fail() { echo "g0b: FAIL: $*" >&2; FAILED=1; }

prepare() {
  HARNESS=$(scripts/harness-build.sh) || { echo "g0b: harness build failed" >&2; exit 1; }
  make -s build || { echo "g0b: go build failed" >&2; exit 1; }
}

# manifest DIR STEP START [STOP]: written once at the start (so a killed run still has one) and
# rewritten with the stop time and outcome at the end.
manifest() {
  local out=$1
  {
    echo "{"
    echo "  \"gate\": \"g0b\", \"step\": \"$2\", \"run_id\": \"$RUN_ID\","
    echo "  \"commit\": \"$(git rev-parse HEAD)\", \"dirty\": $([ -n "$(git status --porcelain)" ] && echo true || echo false),"
    echo "  \"upstream_pin\": \"$UPSTREAM_PIN\","
    echo "  \"host\": \"$(uname -sm) $(sysctl -n hw.model 2>/dev/null || hostname)\","
    echo "  \"go\": \"$(go version)\","
    echo "  \"reads\": \"$READS (SRR062634, 1000 Genomes human WGS)\", \"key_seed\": $SEED,"
    echo "  \"dbs\": \"$DBS\","
    echo "  \"start\": \"$3\", \"stop\": \"${4:-}\", \"failed\": $FAILED"
    echo "}"
  } > "$out/manifest.json"
  cp "$HARNESS/BUILD" "$out/harness-BUILD.txt"
  cp "$K2_READS/$READS.SOURCE" "$out/reads-SOURCE.txt" 2>/dev/null
}

# run_hash DB: keys from upstream's scanner, upstream lookups, Go lookups, comparisons.
run_hash() {
  local db=$1 dir; dir=$(db_dir "$db") || return 1
  if [ ! -s "$dir/SOURCE" ] || [ ! -s "$dir/opts.k2d" ]; then
    echo "g0b hash: $db not fully fetched ($dir); skipping"
    return 0
  fi
  local out="$RES/$db" cache=".cache/g0b/$db"
  mkdir -p "$out" "$cache"
  cp "$dir/SOURCE" "$out/db-SOURCE.txt"
  echo "== g0b hash $db"
  "$HARNESS/chash_keys" "$dir/opts.k2d" "$cache/keys-real.u64" "$cache/keys-random.u64" "$SEED" \
    "$K2_READS/${READS}_1.fq" "$K2_READS/${READS}_2.fq" 2> "$out/keys.txt" \
    || { fail "$db: chash_keys"; return 1; }
  cat "$out/keys.txt"
  local pop v
  for pop in real random; do
    for v in "" .dh; do
      "$HARNESS/chash_dump$v" "$dir/hash.k2d" < "$cache/keys-$pop.u64" > "$cache/up$v-$pop.bin" \
        2> "$out/upstream$v-$pop.txt" || { fail "$db: chash_dump$v $pop"; return 1; }
    done
    echo "-- upstream $pop (linear, as shipped):"; cat "$out/upstream-$pop.txt"
    local K="$BIN/k2probe equiv-hash -hash $dir/hash.k2d -keys $cache/keys-$pop.u64"
    # Acceptance: linear (upstream's default build), both loaders, zero mismatches.
    $K -expect "$cache/up-$pop.bin" -mode linear -load ram -label "$db-$pop" \
      -json "$out/go-linear-ram-$pop.json" | tee "$out/go-linear-ram-$pop.txt" \
      || fail "$db $pop: linear/ram mismatch"
    $K -expect "$cache/up-$pop.bin" -mode linear -load mmap -label "$db-$pop" \
      -json "$out/go-linear-mmap-$pop.json" | tee "$out/go-linear-mmap-$pop.txt" \
      || fail "$db $pop: linear/mmap mismatch"
    # Port check of Double mode against upstream's double-hashing build.
    $K -expect "$cache/up.dh-$pop.bin" -mode double -load ram -label "$db-$pop-vs-upstream-dh" \
      -json "$out/go-double-vs-dh-$pop.json" | tee "$out/go-double-vs-dh-$pop.txt" \
      || fail "$db $pop: double vs upstream double-hashing build mismatch"
    # Evidence for which mode the DB needs: Double against the shipped (linear) upstream; counted.
    $K -expect "$cache/up-$pop.bin" -mode double -load ram -stop=false -label "$db-$pop-double-vs-shipped" \
      -json "$out/go-double-vs-linear-$pop.json" | tee "$out/go-double-vs-linear-$pop.txt"
  done
}

BIN=bin

# step_hash: issue #4 (internal/chash vs upstream CompactHashTable).
step_hash() {
    RES="results/g0b/chash-$RUN_ID"
    mkdir -p "$RES"
    local start; start=$(date -u +%FT%TZ)
    manifest "$RES" hash "$start"
    {
      echo "scripts/g0b.sh hash  (G0B_DBS=\"$DBS\" G0B_RUN_ID=$RUN_ID)"
      echo "per db: chash_keys opts.k2d keys-real.u64 keys-random.u64 $SEED ${READS}_1.fq ${READS}_2.fq"
      echo "        chash_dump{,.dh} hash.k2d < keys-<pop>.u64 > up{,.dh}-<pop>.bin"
      echo "        k2probe equiv-hash -mode linear -load ram|mmap -expect up-<pop>.bin"
      echo "        k2probe equiv-hash -mode double -expect up.dh-<pop>.bin"
      echo "        k2probe equiv-hash -mode double -stop=false -expect up-<pop>.bin"
    } > "$RES/commands.txt"
    local db
    for db in $DBS; do run_hash "$db"; done
    manifest "$RES" hash "$start" "$(date -u +%FT%TZ)"
    summarize_hash > "$RES/summary.md"
}

# summarize_hash: one readable page assembled from the files in $RES (nothing computed here).
summarize_hash() {
  echo "# g0b hash equivalence, run $RUN_ID"
  echo
  echo "Upstream pin \`$UPSTREAM_PIN\`; commit \`$(git rev-parse HEAD)\`. Failed checks: $FAILED."
  echo "Raw per-run files are alongside; \`manifest.json\` has the run metadata."
  echo
  echo '```'; cat "$RES/commands.txt"; echo; cat "$RES/harness-BUILD.txt"; echo '```'
  local d f
  for d in "$RES"/*/; do
    [ -f "$d/db-SOURCE.txt" ] || continue
    echo; echo "## $(basename "$d")"; echo
    echo '```'; cat "$d/db-SOURCE.txt"; echo; cat "$d/keys.txt"; echo '```'
    for f in "$d"/upstream-*.txt "$d"/upstream.dh-*.txt; do
      [ -f "$f" ] || continue
      echo; echo "### $(basename "$f" .txt)"; echo; echo '```'
      grep -E '^(mode|load|load_s|keys|hits|get_ns_per_key|getbatch_ns_per_key)=' "$f" | tr '\n' ' '; echo
      echo '```'
    done
    for f in "$d"/go-*.txt; do
      echo; echo "### $(basename "$f" .txt)"; echo; echo '```'; cat "$f"; echo '```'
    done
  done
}

case "$STEP" in
  hash) prepare; step_hash ;;
  all)  prepare; step_hash ;;
  *) echo "usage: $0 hash|all" >&2; exit 2 ;;
esac

if [ "$FAILED" != 0 ]; then echo "g0b: FAILED" >&2; exit 1; fi
echo "g0b: ok"
