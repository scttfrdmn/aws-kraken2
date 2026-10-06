#!/usr/bin/env bash
# G0b equivalence runs: Go ports vs upstream at the pin, on real reads and real databases.
# See docs/g0b.md.
# Usage: scripts/g0b.sh hash|scan|all
#   hash  internal/chash vs upstream CompactHashTable (issue #4), via upstream/chash_{keys,dump}.cc
#   scan  internal/mmscan vs upstream MinimizerScanner (issue #5), via upstream/mm_dump.cc
# Env:   G0B_DBS         databases for hash (default "viral standard8"; an incomplete download is
#                        skipped)
#        G0B_SCAN_READS  read stems for scan (default "SRR062634_200000 SRR5935746_200000")
#        G0B_RUN_ID      results directory suffix (default: UTC time plus short commit, as g0a;
#                        an existing results directory is never overwritten)
# Writes results/g0b/<step>-<run-id>/ (manifest.json and small summaries) and .cache/g0b/ (key and
# output dumps, not committed). Exits non-zero on any mismatch.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/pin.env
. scripts/paths.sh
echo "g0b: shell flags $-"
INVOCATION="scripts/g0b.sh $*"

STEP=${1:-all}
RUN_ID=${G0B_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)}
DBS=${G0B_DBS:-viral standard8}
SCAN_READS=${G0B_SCAN_READS:-SRR062634_200000 SRR5935746_200000}
READS=SRR062634_200000
SEED=20261005
FAILED=0
BIN=bin

db_dir() {
  case "$1" in
    viral) echo "$K2_DB_ROOT/k2_viral_20260626" ;;
    standard8) echo "$K2_DB_ROOT/k2_standard_08_GB_20260626" ;;
    *) echo "g0b: unknown db $1" >&2; return 1 ;;
  esac
}

# fail MSG: record a failed acceptance check and keep going (the summary says which).
fail() { echo "g0b: FAIL: $*" >&2; FAILED=1; }

# newdir DIR: create a results directory, refusing one that already exists.
newdir() {
  if [ -e "$1" ]; then echo "g0b: $1 exists; refusing to overwrite (set another G0B_RUN_ID)" >&2; exit 1; fi
  mkdir -p "$1"
}

# db_json: the databases' SOURCE lines (source, etag, fetched) as a JSON object.
db_json() {
  local db dir first=1
  printf '{'
  for db in viral standard8; do
    dir=$(db_dir "$db")
    [ -s "$dir/SOURCE" ] || continue
    [ $first = 1 ] || printf ', '
    first=0
    printf '"%s": {"source": "%s", "etag": "%s", "fetched": "%s"}' "$db" \
      "$(awk '$1=="source"{print $2}' "$dir/SOURCE")" \
      "$(awk '$1=="etag"{print $2}' "$dir/SOURCE" | tr -d '"')" \
      "$(awk '$1=="fetched"{print $2}' "$dir/SOURCE")"
  done
  printf '}'
}

dirty() { git diff --quiet HEAD -- . ':!results' && [ -z "$(git ls-files --others --exclude-standard -- . ':!results')" ] && echo false || echo true; }

go_build() { make -s build || { echo "g0b: go build failed" >&2; exit 1; }; }

# manifest DIR STEP START [STOP]: written once at the start (so a killed run still has one) and
# rewritten with the stop time and outcome at the end.
manifest() {
  local out=$1
  {
    echo "{"
    echo "  \"gate\": \"g0b\", \"step\": \"$2\", \"run_id\": \"$RUN_ID\","
    echo "  \"invocation\": \"$INVOCATION\","
    echo "  \"env\": {\"G0B_DBS\": \"$DBS\", \"G0B_SCAN_READS\": \"$SCAN_READS\"},"
    echo "  \"commit\": \"$(git rev-parse HEAD)\", \"dirty\": $(dirty),"
    echo "  \"upstream_pin\": \"$UPSTREAM_PIN\","
    echo "  \"host\": \"$(uname -sm) $(sysctl -n hw.model 2>/dev/null || hostname)\","
    echo "  \"canonical_platform\": \"Linux aarch64; this host is $( [ "$(uname -s)/$(uname -m)" = Linux/aarch64 ] && echo canonical || echo development-only)\","
    echo "  \"go\": \"$(go version)\","
    echo "  \"dbs\": $(db_json),"
    echo "  \"comparisons\": ${COMPARISONS:-0},"
    echo "  \"start\": \"$3\", \"stop\": \"${4:-}\", \"failed\": $FAILED"
    echo "}"
  } > "$out/manifest.json"
}

# ---- hash -------------------------------------------------------------------------------------

# run_hash DB: keys from upstream's scanner, upstream lookups, Go lookups, comparisons.
run_hash() {
  local db=$1 dir; dir=$(db_dir "$db") || return 1
  if [ ! -s "$dir/SOURCE" ] || [ ! -s "$dir/opts.k2d" ]; then
    fail "hash: requested db $db not fully fetched ($dir; scripts/fetch-db.sh)"
    return 1
  fi
  local out="$RES/$db" cache=".cache/g0b/$db"
  mkdir -p "$out" "$cache"
  cp "$dir/SOURCE" "$out/db-SOURCE.txt"
  echo "== g0b hash $db"
  "$H/chash_keys" "$dir/opts.k2d" "$cache/keys" "$SEED" \
    "$K2_READS/${READS}_1.fq" "$K2_READS/${READS}_2.fq" 2> "$out/keys.txt" \
    || { fail "$db: chash_keys"; return 1; }
  cat "$out/keys.txt"
  local pop v
  for pop in real subthreshold random; do
    if [ ! -s "$cache/keys-$pop.u64" ]; then
      # A database that is not downsampled (minimum_acceptable_hash_value 0, e.g. Viral) has
      # no subthreshold minimizers; any other empty population is a failure.
      if [ "$pop" = subthreshold ] && grep -qx 'minimum_acceptable_hash_value=0' "$out/keys.txt"; then
        echo "-- no $pop keys for $db (not downsampled)"; continue
      fi
      fail "hash: $db has no $pop keys"; continue
    fi
    for v in "" .dh; do
      "$H/chash_dump$v" "$dir/hash.k2d" < "$cache/keys-$pop.u64" > "$cache/up$v-$pop.bin" \
        2> "$out/upstream$v-$pop.txt" || { fail "$db: chash_dump$v $pop"; return 1; }
    done
    echo "-- upstream $pop (linear, as shipped):"; cat "$out/upstream-$pop.txt"
    local K="$BIN/k2probe equiv-hash -hash $dir/hash.k2d -keys $cache/keys-$pop.u64"
    # Acceptance: linear (upstream's default build), both loaders, zero mismatches.
    $K -expect "$cache/up-$pop.bin" -mode linear -load ram -label "$db-$pop" \
      -json "$out/go-linear-ram-$pop.json" | tee "$out/go-linear-ram-$pop.txt" \
      || fail "$db $pop: linear/ram mismatch"
    COMPARISONS=$((COMPARISONS + 1))
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

# run_synth40: the 40-bit cell path (CompactHashCell40), which neither pinned database uses. A
# synthetic table is built by upstream itself (upstream/chash_build.cc: CompareAndSet, WriteTable),
# once per probe build, then looked up by upstream (chash_dump) and by Go. Synthetic data: a port
# check of the cell format, not a measurement.
SYN_CAP=1000003; SYN_KB=18; SYN_VB=22; SYN_N=700000
run_synth40() {
  local out="$RES/synthetic40" cache=".cache/g0b/synthetic40" v mode
  mkdir -p "$out" "$cache"
  echo "== g0b hash synthetic 40-bit (capacity $SYN_CAP, key_bits $SYN_KB, value_bits $SYN_VB, $SYN_N keys)"
  for v in "" .dh; do
    "$H/chash_build$v" "$cache/hash$v.k2d" "$SYN_CAP" "$SYN_KB" "$SYN_VB" "$SYN_N" "$SEED" "$cache/keys$v.u64" \
      2> "$out/build$v.txt" || { fail "synthetic40: chash_build$v"; return 1; }
    "$H/chash_dump$v" "$cache/hash$v.k2d" < "$cache/keys$v.u64" > "$cache/up$v.bin" \
      2> "$out/upstream$v.txt" || { fail "synthetic40: chash_dump$v"; return 1; }
  done
  cat "$out/build.txt"
  local K="$BIN/k2probe equiv-hash"
  for mode in ram mmap; do
    $K -hash "$cache/hash.k2d" -keys "$cache/keys.u64" -expect "$cache/up.bin" -mode linear -load $mode \
      -label "synthetic40-linear-$mode" -json "$out/go-linear-$mode.json" | tee "$out/go-linear-$mode.txt" \
      || fail "synthetic40: linear/$mode mismatch"
    COMPARISONS=$((COMPARISONS + 1))
  done
  $K -hash "$cache/hash.dh.k2d" -keys "$cache/keys.dh.u64" -expect "$cache/up.dh.bin" -mode double -load ram \
    -label "synthetic40-double-vs-dh" -json "$out/go-double-vs-dh.json" | tee "$out/go-double-vs-dh.txt" \
    || fail "synthetic40: double vs upstream double-hashing build mismatch"
  COMPARISONS=$((COMPARISONS + 1))
  grep -q '^cell_bytes=5$' "$out/build.txt" || fail "synthetic40: the table is not 40-bit"
}

# summarize_hash: one readable page assembled from the files in $RES (nothing computed here).
summarize_hash() {
  echo "# g0b hash equivalence, run $RUN_ID"
  echo
  echo "Upstream pin \`$UPSTREAM_PIN\`; commit \`$(git rev-parse HEAD)\` (dirty: $(dirty)). Failed checks: $FAILED."
  echo "Raw per-run files are alongside; \`manifest.json\` has the run metadata."
  echo
  echo '```'; cat "$RES/commands.txt"; echo; cat "$RES"/harness-*.BUILD; echo '```'
  local d f
  for d in "$RES"/*/; do
    if [ -f "$d/build.txt" ]; then
      echo; echo "## $(basename "$d") (synthetic table built by upstream; cell-format port check)"; echo
      echo '```'; cat "$d/build.txt"; echo '```'
    else
      [ -f "$d/db-SOURCE.txt" ] || continue
      echo; echo "## $(basename "$d")"; echo
      echo '```'; cat "$d/db-SOURCE.txt"; echo; cat "$d/keys.txt"; echo '```'
    fi
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

step_hash() {
  RES="results/g0b/chash-$RUN_ID"
  newdir "$RES"
  COMPARISONS=0
  local start b; start=$(date -u +%FT%TZ)
  manifest "$RES" hash "$start"
  scripts/harness-build.sh -v lp,dh chash_keys chash_dump chash_build > "$RES/harness-paths.txt" \
    || { fail "harness build"; manifest "$RES" hash "$start" "$(date -u +%FT%TZ)"; return 1; }
  H=$(dirname "$(head -1 "$RES/harness-paths.txt")")
  rm -f "$RES/harness-paths.txt"
  for b in chash_keys chash_dump chash_dump.dh chash_build chash_build.dh; do cp "$H/$b.BUILD" "$RES/harness-$b.BUILD"; done
  cp "$K2_READS/$READS.SOURCE" "$RES/reads-SOURCE.txt" 2>/dev/null
  {
    echo "$INVOCATION  (G0B_DBS=\"$DBS\" G0B_RUN_ID=$RUN_ID)"
    echo "per db: chash_keys opts.k2d keys $SEED ${READS}_1.fq ${READS}_2.fq"
    echo "        (pop = real, subthreshold, random; keys-<pop>.u64)"
    echo "        chash_dump{,.dh} hash.k2d < keys-<pop>.u64 > up{,.dh}-<pop>.bin"
    echo "        k2probe equiv-hash -mode linear -load ram|mmap -expect up-<pop>.bin"
    echo "        k2probe equiv-hash -mode double -expect up.dh-<pop>.bin"
    echo "        k2probe equiv-hash -mode double -stop=false -expect up-<pop>.bin"
    echo "synthetic 40-bit: chash_build{,.dh} hash{,.dh}.k2d $SYN_CAP $SYN_KB $SYN_VB $SYN_N $SEED keys{,.dh}.u64"
    echo "        chash_dump{,.dh} hash{,.dh}.k2d < keys{,.dh}.u64 > up{,.dh}.bin"
    echo "        k2probe equiv-hash -mode linear -load ram|mmap (vs up.bin); -mode double (vs up.dh.bin)"
  } > "$RES/commands.txt"
  local db
  for db in $DBS; do run_hash "$db"; done
  run_synth40
  [ "$COMPARISONS" -gt 0 ] || fail "hash: zero comparisons made"
  manifest "$RES" hash "$start" "$(date -u +%FT%TZ)"
  summarize_hash > "$RES/summary.md"
}

# ---- scan -------------------------------------------------------------------------------------

step_scan() {
  local out="results/g0b/scan-$RUN_ID" log sum fails=0 start
  start=$(date -u +%FT%TZ)
  newdir "$out"; COMPARISONS=0; log="$out/scan.log"; sum="$out/summary.txt"; : > "$log"; : > "$sum"
  manifest "$out" scan "$start"
  { echo "shell flags: $-"; echo "invocation: $INVOCATION"; echo "G0B_SCAN_READS=$SCAN_READS"; } >> "$log"
  {
    echo "commit $(git rev-parse HEAD) dirty=$(dirty)"
    echo "upstream $UPSTREAM_REPO @ $UPSTREAM_PIN"
    echo "date $(date -u +%FT%TZ) host $(uname -sm)"
    echo "go $(go env GOVERSION)"
  } >> "$sum"
  local harness
  harness=$(scripts/harness-build.sh mm_dump) || { fail "scan: harness build failed"; return 1; }
  sed 's/^/harness /' "$harness.BUILD" >> "$sum"

  local viral std8 st db
  viral=$(db_dir viral); std8=$(db_dir standard8)
  [ -s "$viral/opts.k2d" ] || { fail "scan: no Viral DB at $viral (scripts/fetch-db.sh)"; return 1; }
  local stems=($SCAN_READS) sets=()
  for st in "${stems[@]}"; do
    if [ -s "$K2_READS/${st}_1.fq" ] && [ -s "$K2_READS/${st}_2.fq" ]; then
      sets+=("$st")
    else
      echo "missing reads $st (scripts/fetch-reads.sh)" | tee -a "$sum"
      fail "scan: requested read set $st absent"
    fi
  done
  [ ${#sets[@]} -gt 0 ] || { fail "scan: no read sets"; return 1; }
  for db in "$viral" "$std8"; do
    [ -s "$db/SOURCE" ] && sed "s|^|db $(basename "$db") |" "$db/SOURCE" >> "$sum"
  done
  for st in "${sets[@]}"; do
    sed "s|^|reads $st |" "$K2_READS/$st.SOURCE" >> "$sum"
  done

  # case: label | opts.k2d | read stem | extra flags
  local cases=()
  for st in "${sets[@]}"; do cases+=("viral|$viral/opts.k2d|$st|"); done
  if [ -s "$std8/opts.k2d" ]; then
    for st in "${sets[@]}"; do cases+=("standard-8|$std8/opts.k2d|$st|"); done
  else
    echo "missing standard-8 (no $std8/opts.k2d)" | tee -a "$sum"
    fail "scan: Standard-8 opts.k2d absent (scripts/fetch-db.sh standard8)"
  fi
  # Scanner-path coverage on real reads with synthetic options (not DB configurations):
  # sub-intervals, pre-2.0.8 revcom, the k == l short circuit, other k/l/masks, protein.
  local st0=${sets[0]} f
  for f in "-r" "-R 0 -r" "-k 31 -l 31 -r" "-k 10 -l 5 -s 0 -t 0 -r" "-k 25 -l 20 -s 0 -r" \
           "-k 64 -l 31 -r" "-P -k 15 -l 12 -s 0 -r" "-P -k 12 -l 12 -r"; do
    cases+=("viral-variant|$viral/opts.k2d|$st0|$f")
  done

  local c label opts flags line rc o
  for c in "${cases[@]}"; do
    IFS='|' read -r label opts st flags <<< "$c"
    echo "== $label $st $flags" >> "$log"
    echo "+ $BIN/k2probe equiv-scan -harness $harness $flags $opts $K2_READS/${st}_1.fq $K2_READS/${st}_2.fq" >> "$log"
    # shellcheck disable=SC2086
    o=$("$BIN/k2probe" equiv-scan -harness "$harness" $flags "$opts" \
      "$K2_READS/${st}_1.fq" "$K2_READS/${st}_2.fq" 2>&1)
    rc=$?
    printf '%s\n' "$o" >> "$log"
    line=$(printf '%s\n' "$o" | grep -E '^(opts k=|MATCH|k2probe)' | tr '\n' ' ')
    [ $rc -eq 0 ] || fails=$((fails + 1))
    COMPARISONS=$((COMPARISONS + 1))
    echo "case $label reads=$st flags='${flags}' rc=$rc :: $line" | tee -a "$sum"
  done
  echo "failures $fails" | tee -a "$sum"
  [ $fails -eq 0 ] || fail "scan: $fails case(s) mismatched"
  [ "$COMPARISONS" -gt 0 ] || fail "scan: zero comparisons made"
  manifest "$out" scan "$start" "$(date -u +%FT%TZ)"
  echo "$out"
}

case "$STEP" in
  hash) go_build; step_hash ;;
  scan) go_build; step_scan ;;
  all)  go_build; step_scan; step_hash ;;
  *) echo "usage: $0 hash|scan|all" >&2; exit 2 ;;
esac

if [ "$FAILED" != 0 ]; then echo "g0b: FAILED" >&2; exit 1; fi
echo "g0b: ok"
