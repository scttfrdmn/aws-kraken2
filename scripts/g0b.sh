#!/usr/bin/env bash
# G0b equivalence probes against upstream at the pin. See docs/g0b.md.
# Usage: scripts/g0b.sh scan|all
#   scan  internal/mmscan vs upstream MinimizerScanner (issue #5), via upstream/mm_dump.cc
# Writes results/g0b/<part>-<UTC date>/{summary.txt,<part>.log}. Exits non-zero on any mismatch.
set +e
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
PART=${1:?usage: scripts/g0b.sh scan|all}
# Large inputs live in .cache/; a worktree without one uses the main checkout's.
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
CACHE=${K2_CACHE:-$PWD/.cache}
[ -d "$CACHE/db" ] || CACHE="$MAIN/.cache"
DATE=$(date -u +%Y%m%d)

provenance() {  # $1 = summary file
  {
    echo "commit $(git rev-parse HEAD)$(git diff --quiet HEAD -- . 2>/dev/null || echo ' (dirty)')"
    echo "upstream $UPSTREAM_REPO @ $UPSTREAM_PIN"
    echo "date $(date -u +%FT%TZ) host $(uname -sm)"
    echo "go $(go env GOVERSION)"
  } >> "$1"
}

scan() {
  local out="results/g0b/scan-$DATE" log sum fails=0
  mkdir -p "$out"; log="$out/scan.log"; sum="$out/summary.txt"; : > "$log"; : > "$sum"
  echo "shell flags: $-" >> "$log"
  provenance "$sum"
  local harness
  harness=$(scripts/harness-build.sh mm_dump) || { echo "g0b scan: harness build failed" >&2; return 1; }
  sed 's/^/harness /' "$harness.BUILD" >> "$sum"
  go build -trimpath -o bin/ ./cmd/k2probe || { echo "g0b scan: go build failed" >&2; return 1; }

  local viral="$CACHE/db/k2_viral_20260626" std8="$CACHE/db/k2_standard_08_GB_20260626"
  [ -s "$viral/opts.k2d" ] || { echo "g0b scan: no Viral DB at $viral (scripts/fetch-db.sh)" >&2; return 1; }
  local stems=(${G0B_SCAN_READS:-SRR062634_200000 SRR5935746_200000}) sets=()
  for st in "${stems[@]}"; do
    if [ -s "$CACHE/reads/${st}_1.fq" ] && [ -s "$CACHE/reads/${st}_2.fq" ]; then
      sets+=("$st")
    else
      echo "skip reads $st (absent; scripts/fetch-reads.sh)" | tee -a "$sum"
    fi
  done
  [ ${#sets[@]} -gt 0 ] || { echo "g0b scan: no read sets" >&2; return 1; }
  for db in "$viral" "$std8"; do
    [ -s "$db/SOURCE" ] && sed "s|^|db $(basename "$db") |" "$db/SOURCE" >> "$sum"
  done
  for st in "${sets[@]}"; do
    sed "s|^|reads $st |" "$CACHE/reads/$st.SOURCE" >> "$sum"
  done

  # case: label | opts.k2d | read stem | extra flags
  local cases=()
  for st in "${sets[@]}"; do cases+=("viral|$viral/opts.k2d|$st|"); done
  if [ -s "$std8/opts.k2d" ]; then
    for st in "${sets[@]}"; do cases+=("standard-8|$std8/opts.k2d|$st|"); done
  else
    echo "skip standard-8 (no $std8/opts.k2d)" | tee -a "$sum"
  fi
  # Scanner-path coverage on real reads with synthetic options (not DB configurations):
  # sub-intervals, pre-2.0.8 revcom, the k == l short circuit, other k/l/masks, protein.
  local st0=${sets[0]}
  for f in "-r" "-R 0 -r" "-k 31 -l 31 -r" "-k 10 -l 5 -s 0 -t 0 -r" "-k 25 -l 20 -s 0 -r" \
           "-k 64 -l 31 -r" "-P -k 15 -l 12 -s 0 -r" "-P -k 12 -l 12 -r"; do
    cases+=("viral-variant|$viral/opts.k2d|$st0|$f")
  done

  local c label opts st flags line rc o
  for c in "${cases[@]}"; do
    IFS='|' read -r label opts st flags <<< "$c"
    echo "== $label $st $flags" >> "$log"
    echo "+ bin/k2probe equiv-scan -harness $harness $flags $opts $CACHE/reads/${st}_1.fq $CACHE/reads/${st}_2.fq" >> "$log"
    # shellcheck disable=SC2086
    o=$(bin/k2probe equiv-scan -harness "$harness" $flags "$opts" \
      "$CACHE/reads/${st}_1.fq" "$CACHE/reads/${st}_2.fq" 2>&1)
    rc=$?
    printf '%s\n' "$o" >> "$log"
    line=$(printf '%s\n' "$o" | grep -E '^(opts k=|MATCH|k2probe:)' | tr '\n' ' ')
    [ $rc -eq 0 ] || fails=$((fails + 1))
    echo "case $label reads=$st flags='${flags}' rc=$rc :: $line" | tee -a "$sum"
  done
  echo "failures $fails" | tee -a "$sum"
  echo "$out"
  [ $fails -eq 0 ]
}

case "$PART" in
  scan) scan ;;
  all) scan ;;
  *) echo "usage: scripts/g0b.sh scan|all" >&2; exit 2 ;;
esac
